defmodule StatifierRouter.Routes do
  @moduledoc """
  The publish-time checks a host runs over a chart before it lets that
  chart reach a route (ADR-0005, decision 7).

  This package has no publish step and gains none here. A host calls
  these two functions from its own - when it saves a revision, when it
  compiles a document in CI, when an author presses publish - and decides
  for itself whether a finding blocks the save or only warns. Both are
  pure and total: they read a compiled `t:Statifier.Machine.t/0` and a
  resolved `t:StatifierRouter.Config.t/0`, touch no process, no clock and
  no database, and add no `Statifier.Validator` finding. The engine's
  equivalent check refuses to add one for its own half (st-ADR-0069,
  decision 3) and this one keeps that posture.

  ## The two halves, and why they are two

  A `<send>` meant for this package writes the host's processor in `type`
  and the **route name** in `target` (ADR-0005, decision 1). Those two
  slots fail independently, and nothing in the engine can check the
  second.

  - `unsupported_types/2` answers the **type** half by composing
    `Statifier.Send.Types.unsupported_sends/2` over the snapshot this
    configuration hands statifier_persistence. A type the host never
    registered is 6.2.5's `error.execution` at run time.
  - `unregistered/2` answers the **route name** half, and it is this
    package's to build because the engine cannot build it. For a
    registered type the engine never parses `target` -
    `Statifier.Send.Processor`'s moduledoc calls it "the processor's own
    opaque route string: the library never parses it" - so a chart that
    names its type correctly and then sends to a route name the host
    never registered gets nothing at all from the engine's check. At run
    time that send misses the registry, is recorded as a refusal and
    reported as an error, and the step still commits (ADR-0005, section
    7). This function is what finds it before a chart ships.

  ## What cannot be checked

  Only a **literal** attribute can be checked. A `targetexpr` or a
  `typeexpr` compiles to `{:compiled, _, _}` and resolves against the
  datamodel at execute time, so no publish-time pass can know what it
  will name. Such a send is never reported as a finding and never
  silently dropped: `unregistered/2` returns it under `:unchecked`, with
  which attribute deferred it, so a host can surface the gap it cannot
  close. The core's own check at execute time stays the backstop for
  both, exactly as it is for the engine's function.

  ## The reserved name

  `StatifierRouter.SendHandler.execution_target/0` is not a route and is
  never reported. A send that writes it names another durable execution
  (ADR-0006, section 1), and `StatifierRouter.Config.new/1` refuses a
  registry entry under it, so it is registered by reservation rather than
  by the host.

  ## An example

  The impression-and-click join's outbound half writes two route names
  (ADR-0005). A host that registered only one of them learns which before
  the chart ships:

      iex> {:ok, config} =
      ...>   StatifierRouter.Config.new(
      ...>     repo: MyApp.Repo,
      ...>     delivery: MyApp.Delivery,
      ...>     send_type: "myapp:sink",
      ...>     route_adapters: %{"joined_records" => {StatifierRouter.RecordingRoute, %{}}}
      ...>   )
      iex> {:ok, machine} = Statifier.compile(StatifierRouter.DeliveryFixtures.join_sends())
      iex> %{unregistered: findings, unchecked: []} =
      ...>   StatifierRouter.Routes.unregistered(config, machine)
      iex> Enum.map(findings, & &1.route)
      ["dead_letter"]
  """

  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Parser.Location
  alias Statifier.Send.Types
  alias StatifierRouter.Config
  alias StatifierRouter.SendHandler

  @typedoc """
  One `<send>` of the configuration's own type whose literal `target`
  names no registered route: the route name, and the `<send>` element's
  location. `route` is `nil` when the send writes no `target` at all,
  which names no route and so can never resolve.
  """
  @type finding :: %{route: String.t() | nil, location: Location.t()}

  @typedoc """
  One `<send>` this pass could not judge, and which attribute deferred
  it: `:typeexpr` when the type is an expression, so whether the send is
  this configuration's at all is unknown; `:targetexpr` when the type is
  the configuration's and the route name is an expression.
  """
  @type unchecked :: %{reason: :typeexpr | :targetexpr, location: Location.t()}

  @typedoc "What `unregistered/2` answers, each list in `c_index` order."
  @type report :: %{unregistered: [finding()], unchecked: [unchecked()]}

  @doc """
  Every `<send>` in `machine` whose literal `type` is this
  configuration's `:send_type` and whose literal `target` names no route
  in its `:route_adapters`, with the sends this pass could not judge
  beside them. Both lists are in `c_index` order, which is document
  order.

  `:send_type` rather than the whole registered set is deliberate: it is
  what `StatifierRouter.SendHandler` answers to, so it is exactly the set
  of sends that will reach this package's registry at run time. A
  configuration with no `:send_type` claims no send, and every list is
  empty.

  The reserved `StatifierRouter.SendHandler.execution_target/0` is never
  a finding (ADR-0006, section 1). An expression in `target` or `type` is
  never a finding either; see the moduledoc.
  """
  @spec unregistered(Config.t(), Machine.t()) :: report()
  def unregistered(%Config{} = config, %Machine{contents: contents}) do
    contents
    |> Tuple.to_list()
    |> Enum.reduce(%{unregistered: [], unchecked: []}, &classify(config, &1, &2))
    |> Map.new(fn {key, reversed} -> {key, Enum.reverse(reversed)} end)
  end

  @doc """
  Every `<send>` in `machine` whose literal `type` is outside the set
  this configuration registers, with the `<send>` element's location, in
  `c_index` order.

  This is `Statifier.Send.Types.unsupported_sends/2` composed over the
  `Statifier.Send.Types` snapshot on this configuration's
  `:persistence_options` - the same snapshot every create and every step
  of every delivery carries, so what this pass judges is what the
  execution will be started with (ADR-0005, decision 6). A configuration
  carrying no snapshot is judged as "no declaration", under which every
  non-built-in type is unsupported.

  It cannot see a `typeexpr`, and says so in its own `@doc`; that half is
  `unregistered/2`'s `:unchecked` list.
  """
  @spec unsupported_types(Config.t(), Machine.t()) :: [Types.unsupported_send()]
  def unsupported_types(%Config{persistence_options: options}, %Machine{} = machine),
    do: Types.unsupported_sends(machine, Keyword.get(options, :send_types))

  # One compiled executable-content node. Only a `<send>` is looked at;
  # every other node passes through untouched.
  @spec classify(Config.t(), Content.t(), report()) :: report()
  defp classify(%Config{} = config, %Content.Send{} = node, acc) do
    case node.type do
      {:compiled, _compiled, _source} ->
        add(acc, :unchecked, %{reason: :typeexpr, location: node.location})

      {:static, type} ->
        # `is_binary/1` is defensive-only: `Config.new/1` admits a string
        # or nil and a literal type is a string, so the comparison alone
        # already fails for a configuration with no `:send_type`. It is
        # kept so that rule does not rest on either of those two facts.
        if is_binary(config.send_type) and type == config.send_type,
          do: check_target(config, node, acc),
          else: acc

      nil ->
        acc
    end
  end

  defp classify(%Config{}, _node, acc), do: acc

  # The route-name half, for a send this configuration's handler will be
  # handed. `Config.route/3` is the run-time lookup and it resolves a
  # name in every scope alike - a scope overrides a route's
  # configuration and never its existence (ADR-0005, decision 2) - so a
  # miss here is a miss everywhere, and no scope is needed to find one.
  @spec check_target(Config.t(), Content.Send.t(), report()) :: report()
  defp check_target(_config, %Content.Send{target: {:compiled, _compiled, _source}} = node, acc),
    do: add(acc, :unchecked, %{reason: :targetexpr, location: node.location})

  defp check_target(config, %Content.Send{target: {:static, name}} = node, acc)
       when is_binary(name) do
    if name == SendHandler.execution_target() or Map.has_key?(config.route_adapters, name),
      do: acc,
      else: add(acc, :unregistered, %{route: name, location: node.location})
  end

  defp check_target(_config, %Content.Send{} = node, acc),
    do: add(acc, :unregistered, %{route: nil, location: node.location})

  @spec add(report(), :unregistered | :unchecked, finding() | unchecked()) :: report()
  defp add(acc, key, entry), do: Map.update!(acc, key, &[entry | &1])
end
