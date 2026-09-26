defmodule StatifierRouter.Contracts do
  @moduledoc """
  The receiver contract at publish: whether the event a sender or a
  binding names is one the receiving document accepts (ADR-0008).

  Two things in this package name an event another document's chart is
  expected to take. A binding names one in its `event`, and a `<send>`
  to the reserved execution target names one in its `event` and the
  receiving document in its `document` param (ADR-0006, section 1). When
  either name is one the receiving chart never listens for, nothing at
  run time refuses it: the event is delivered and recorded as delivered,
  and the receiver's step selects no transition (ADR-0008, decision 5).
  These functions find it before a chart or a configuration ships.

  This package has no publish step and gains none here. A host calls
  these functions from its own - when it saves a revision, when it
  compiles a document in CI, when an author presses publish - and an
  editor calls them at edit time. The host decides whether a finding
  blocks the publish or only warns (ADR-0008, decision 6). They are pure
  over their arguments: a resolved `t:StatifierRouter.Config.t/0`, a
  compiled `t:Statifier.Machine.t/0` and the host's lookup, which is the
  only call that reaches outside them. Nothing here adds a
  `Statifier.Validator` finding.

  ## The lookup

  The host supplies an arity-1 function from a receiving document id to
  one of three answers (ADR-0008, decision 2):

  - `{:ok, names}` - the receiver declares these event names. An event
    is accepted when it is equal, as a string, to one of them. `[]` is a
    declaration that accepts nothing.
  - `{:ok, :undeclared, machine}` - the receiver declares nothing, and
    `machine` is the chart a new execution of it would start on. Its
    contract is the engine's computed vocabulary: an event is accepted
    when `Statifier.Chart.check_accepts(machine, [event])` answers
    `unreachable: []`. The package never matches descriptors itself.
  - `{:error, :not_published}` - the receiver has no published chart.

  Any other answer is the host's fault, and the function raises
  `ArgumentError`. The lookup takes no scope: the host builds it over the
  scope it is publishing into (ADR-0008, decision 2).

  ## The reasons

  A finding carries `reason`, which says which contract refused it
  (ADR-0008, decisions 2 and 4, and its 2026-09-23 Amendment):

  - `:undeclared` - the receiver declares names and this is not one.
  - `:undeclared_by_computed_set` - the receiver declares nothing, and no
    reachable transition of its chart matches this name.
  - `:not_published` - the lookup answered `{:error, :not_published}`.
  - `:delay` - the `<send>` writes `delay` or `delayexpr`. A delayed send
    to the execution target is never delivered, so the lookup is not
    asked. A binding has no delay and never carries this reason.

  ## The route findings

  `check/3` also carries every `<send>` of the configuration's type that
  will never be handed to the route its literal `target` names, under
  `:unregistered_routes`, each entry `%{route, location, reason}`
  (ADR-0008's 2026-09-24 Amendment):

  - `:unregistered` - the `target` names no registered route, or the send
    writes no `target`: `StatifierRouter.Routes.unregistered/2`'s finding.
  - `:no_timer_queue` - the `target` names a registered route, the send
    writes a literal `delay`, and the configuration has no
    `:timer_queue`, so `StatifierRouter.SendHandler` never queues it and
    refuses it, as `{:no_timer_queue, send_id}` once the route resolves.
    A send to the reserved execution target is never this finding; its
    delay is a `:delay` finding above.

  ## The finding reasons are closed

  `t:reason/0`, and so the three of them a `t:binding_finding/0` carries,
  and `t:route_reason/0` are closed sets (ADR-0008's 2026-09-24
  Amendment). A host may match on them exhaustively. A new reason arrives
  only with a record that decides it, in a minor release whose changelog
  names it as breaking.

  ## What cannot be checked

  Only a literal can be judged. A send `undeclared_events/3` selects but
  cannot judge is never a finding and never passed silently: it is
  reported under `:unchecked` as `%{reason: reason, location: location}`,
  the shape `StatifierRouter.Routes.unregistered/2`'s own unchecked
  entries have (ADR-0008, decision 3). The reasons are `:eventexpr`,
  `:no_event`, `:document_expr` and `:no_document`; see `t:unchecked/0`.
  A delayed send that cannot be judged keeps its unchecked entry and is
  not a `:delay` finding.
  A send whose `type` or `target` is an expression is not selected here
  at all: `StatifierRouter.Routes.unregistered/2` reports it, and
  `check/3` carries that list once.

  A configuration that gives a `:bindings_resolver` has no bindings
  `check/3` can read, and `check/3` never calls the resolver. Its report
  says so: the first `:unchecked` entry is
  `%{reason: :bindings_resolver, location: nil}`, the one entry with no
  location (see `t:bindings_unchecked/0`), so the report is never the one
  a clean pass answers (ADR-0008's 2026-09-26 Amendment).

  ## An example

  A parcel is scanned from depot to doorstep. The `parcel` document
  declares the two events its chart takes, and a third binding routes
  the depot's missing-parcel report as an event the parcel never
  declared:

      iex> lookup = fn
      ...>   "parcel" -> {:ok, ["parcel.scanned", "parcel.delivered"]}
      ...>   _other -> {:error, :not_published}
      ...> end
      iex> {:ok, lost} =
      ...>   StatifierRouter.Binding.new(
      ...>     id: "depot_lost",
      ...>     source: "depot_feed",
      ...>     match: "event.kind == 'lost'",
      ...>     key: "event.parcel_id",
      ...>     document: "parcel",
      ...>     event: "parcel.lost"
      ...>   )
      iex> StatifierRouter.Contracts.undeclared_binding_events([lost], lookup)
      [%{event: "parcel.lost", document: "parcel", binding_id: "depot_lost", reason: :undeclared}]
  """

  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Routes
  alias StatifierRouter.SendHandler

  @typedoc """
  Which contract refused a name; see the moduledoc. `:delay` is a
  `<send>`'s only; a binding finding never carries it. A closed set.
  """
  @type reason :: :undeclared | :undeclared_by_computed_set | :not_published | :delay

  @typedoc """
  Why a `<send>` of the configuration's type is not handed to the route
  its literal `target` names; see the moduledoc. A closed set.
  """
  @type route_reason :: :unregistered | :no_timer_queue

  @typedoc """
  One entry under `check/3`'s `:unregistered_routes`: the route name, the
  `<send>` element's location and the reason. `route` is `nil` only for
  an `:unregistered` send that writes no `target`. It is
  `t:StatifierRouter.Routes.finding/0` with `reason` added, so a pattern
  on `route` and `location` alone matches every entry.
  """
  @type route_finding :: %{
          route: String.t() | nil,
          location: Location.t(),
          reason: route_reason()
        }

  @typedoc """
  The host's lookup: a receiving document id to its declared names, to
  `{:ok, :undeclared, machine}` when it declares none, or to
  `{:error, :not_published}`.
  """
  @type lookup ::
          (document :: String.t() ->
             {:ok, [String.t()]}
             | {:ok, :undeclared, Machine.t()}
             | {:error, :not_published})

  @typedoc """
  One execution-target `<send>` whose literal event its receiver does not
  accept, or which is delayed: the event, the receiving document, the
  `<send>` element's location and the reason.
  """
  @type finding :: %{
          event: String.t(),
          document: String.t(),
          location: Location.t(),
          reason: reason()
        }

  @typedoc """
  One execution-target `<send>` this pass could not judge, and why:

  - `:eventexpr` - the event is an expression (`eventexpr`).
  - `:no_event` - the send writes neither `event` nor `eventexpr`.
  - `:document_expr` - a `document` is given and is not a literal: an
    expression other than exactly one `lit` of a non-empty string, a
    `location`, a `namelist` entry, or more than one param of that name.
  - `:no_document` - no `document` param and no `namelist` entry of that
    name.

  When both the event and the document are uncheckable, the event's
  reason is the one reported.
  """
  @type unchecked :: %{
          reason: :eventexpr | :no_event | :document_expr | :no_document,
          location: Location.t()
        }

  @typedoc """
  The `:unchecked` entry `check/3` puts first when the configuration
  gives a `:bindings_resolver`: the bindings were not checked, because
  `check/3` takes no scope and never calls the resolver. It is the one
  unchecked entry with no location; a host checks each scope's bindings
  with `undeclared_binding_events/2`.
  """
  @type bindings_unchecked :: %{reason: :bindings_resolver, location: nil}

  @typedoc "What `undeclared_events/3` answers, each list in `c_index` order."
  @type report :: %{undeclared: [finding()], unchecked: [unchecked()]}

  @typedoc """
  One binding whose event its document does not accept: the event, the
  document, the binding's id and the reason.
  """
  @type binding_finding :: %{
          event: String.t(),
          document: String.t(),
          binding_id: String.t(),
          reason: :undeclared | :undeclared_by_computed_set | :not_published
        }

  @typedoc "What `check/3` answers; see its `@doc`."
  @type check_report :: %{
          unsupported_types: [Statifier.Send.Types.unsupported_send()],
          unregistered_routes: [route_finding()],
          unchecked: [bindings_unchecked() | Routes.unchecked() | unchecked()],
          undeclared_events: [finding()],
          undeclared_binding_events: [binding_finding()]
        }

  @doc """
  Every execution-target `<send>` in `machine` whose literal event its
  receiving document does not accept, with the sends this pass could not
  judge beside them. Both lists are in `c_index` order, which is document
  order.

  A send is selected when its `type` is the literal configuration's
  `:send_type` and its `target` is the literal
  `StatifierRouter.SendHandler.execution_target/0` (ADR-0008, decision
  1). A configuration with no `:send_type` selects nothing.

  A selected send is judged when its event is literal and its `document`
  param is literal: exactly one `<param>` named `document`, no `namelist`
  entry of that name, written with `expr`, compiling to exactly the one
  instruction `["lit", value]` with `value` a non-empty string. `value`
  is the receiving document, and `lookup.(value)` decides:

  - `{:ok, names}` - a finding with reason `:undeclared` unless the event
    equals one of `names`.
  - `{:ok, :undeclared, machine}` - a finding with reason
    `:undeclared_by_computed_set` unless
    `Statifier.Chart.check_accepts(machine, [event])` answers
    `unreachable: []`. This is the fallback for a receiver that declares
    nothing, and it is the engine's relation, not a copy of it.
  - `{:error, :not_published}` - a finding with reason `:not_published`.

  A judged send that writes `delay` or `delayexpr` is a finding with
  reason `:delay` instead, and the lookup is not called for it: a delayed
  send to the execution target is refused at run time whatever its event
  (ADR-0008's 2026-09-23 Amendment). A delayed send that cannot be judged
  is an unchecked entry like any other.

  A finding is `%{event, document, location, reason}`. A selected send
  that cannot be judged is an unchecked entry `%{reason, location}` with
  reason `:eventexpr`, `:no_event`, `:document_expr` or `:no_document`
  (see `t:unchecked/0`). Raises `ArgumentError` when the lookup answers
  anything else.
  """
  @spec undeclared_events(Config.t(), Machine.t(), lookup()) :: report()
  def undeclared_events(%Config{} = config, %Machine{contents: contents}, lookup)
      when is_function(lookup, 1) do
    contents
    |> Tuple.to_list()
    |> Enum.reduce(%{undeclared: [], unchecked: []}, &classify(config, lookup, &1, &2))
    |> Map.new(fn {key, reversed} -> {key, Enum.reverse(reversed)} end)
  end

  @doc """
  Every binding in `bindings` whose event its document does not accept,
  in the order of `bindings`.

  A binding's `document` and `event` are always literal strings, so every
  binding is judged and none is unchecked (ADR-0008, decision 1). The
  lookup decides exactly as it does for `undeclared_events/3`, with the
  same three reasons: `:undeclared` under a declaration,
  `:undeclared_by_computed_set` under the computed vocabulary
  (`Statifier.Chart.check_accepts/2`), and `:not_published`. A finding is
  `%{event, document, binding_id, reason}`. Raises `ArgumentError` when
  the lookup answers anything else.

  A host whose declarations differ by scope calls this once per scope,
  with one lookup each (ADR-0008, decision 2).
  """
  @spec undeclared_binding_events([Binding.t()], lookup()) :: [binding_finding()]
  def undeclared_binding_events(bindings, lookup)
      when is_list(bindings) and is_function(lookup, 1) do
    Enum.flat_map(bindings, fn %Binding{} = binding ->
      case judge(lookup, binding.document, binding.event) do
        nil ->
          []

        reason ->
          [
            %{
              event: binding.event,
              document: binding.document,
              binding_id: binding.id,
              reason: reason
            }
          ]
      end
    end)
  end

  @doc """
  Every publish-time check this package ships, over one configuration,
  one compiled machine and the host's lookup, in one report under five
  keys (ADR-0008, decision 6):

  - `:unsupported_types` - `StatifierRouter.Routes.unsupported_types/2`.
  - `:unregistered_routes` - every `<send>` of the configuration's type
    that is never handed to the route its literal `target` names, as
    `%{route, location, reason}` in document order: each entry of the
    `:unregistered` list of `StatifierRouter.Routes.unregistered/2` with
    reason `:unregistered`, and each send that writes a literal `delay`
    to a registered route while the configuration has no `:timer_queue`,
    with reason `:no_timer_queue` (see `t:route_finding/0`).
  - `:unchecked` - the unchecked entries of
    `StatifierRouter.Routes.unregistered/2` (`:typeexpr`, `:targetexpr`)
    and of `undeclared_events/3` together, in document order, ordered by
    each `<send>` element's source offset. When the configuration gives a
    `:bindings_resolver`, `%{reason: :bindings_resolver, location: nil}`
    comes first (see `t:bindings_unchecked/0`); without one it is absent.
  - `:undeclared_events` - the findings of `undeclared_events/3`.
  - `:undeclared_binding_events` - `undeclared_binding_events/2` over the
    configuration's `:bindings`. A configuration that gives a
    `:bindings_resolver` keeps `bindings: []`, so this key is always empty
    for it: `check/3` takes no scope and never calls the resolver, and the
    host checks each scope's answer with `undeclared_binding_events/2`
    itself (ADR-0001, the Amendment of 2026-09-25). The
    `:bindings_resolver` entry under `:unchecked` is what tells that empty
    list from a clean pass (ADR-0008's 2026-09-26 Amendment).

  `StatifierRouter.Routes.unsupported_types/2` is composed unchanged, and
  so are the `:unchecked` entries of `StatifierRouter.Routes.unregistered/2`;
  its `:unregistered` entries each gain `reason: :unregistered`, and
  nothing else about them changes. A finding under either
  `:undeclared_events` or `:undeclared_binding_events` carries one of the
  three reasons, `:undeclared`, `:undeclared_by_computed_set` (the
  receiver declares nothing and `Statifier.Chart.check_accepts/2` finds
  no reachable transition for the name) or `:not_published`; a finding
  under `:undeclared_events` may instead carry `:delay`, for a judged
  `<send>` that writes `delay` or `delayexpr`. Every
  `:unchecked` entry is `%{reason, location}`, its reason one of
  `:typeexpr`, `:targetexpr`, `:eventexpr`, `:no_event`, `:document_expr`
  or `:no_document`, with a `<send>` element's location, except the one
  `:bindings_resolver` entry, whose location is `nil`. Which finding
  blocks a publish is the host's decision.
  """
  @spec check(Config.t(), Machine.t(), lookup()) :: check_report()
  def check(%Config{} = config, %Machine{} = machine, lookup) when is_function(lookup, 1) do
    routes = Routes.unregistered(config, machine)
    events = undeclared_events(config, machine, lookup)

    %{
      unsupported_types: Routes.unsupported_types(config, machine),
      unregistered_routes: route_findings(config, machine, routes.unregistered),
      unchecked:
        bindings_unchecked(config) ++
          Enum.sort_by(routes.unchecked ++ events.unchecked, & &1.location.start_offset),
      undeclared_events: events.undeclared,
      undeclared_binding_events: undeclared_binding_events(config.bindings, lookup)
    }
  end

  # ADR-0008's 2026-09-26 Amendment: a configuration with a bindings
  # resolver has no bindings this check reads, and says so first, before
  # the located entries, which the sort above orders by offset.
  @spec bindings_unchecked(Config.t()) :: [bindings_unchecked()]
  defp bindings_unchecked(%Config{bindings_resolver: nil}), do: []

  defp bindings_unchecked(%Config{}), do: [%{reason: :bindings_resolver, location: nil}]

  # ADR-0008's 2026-09-24 Amendment: `Routes.unregistered/2`'s findings,
  # each tagged `:unregistered`, and the delayed route sends a host with
  # no timer queue refuses, merged in document order.
  @spec route_findings(Config.t(), Machine.t(), [Routes.finding()]) :: [route_finding()]
  defp route_findings(config, machine, unregistered) do
    unregistered
    |> Enum.map(&Map.put(&1, :reason, :unregistered))
    |> Kernel.++(unqueued(config, machine))
    |> Enum.sort_by(& &1.location.start_offset)
  end

  # A `<send>` of the configuration's literal type whose literal `target`
  # is a registered route and which writes a literal `delay`, on a
  # configuration with no timer queue. The reserved execution target is
  # never a registered route (`Config.new/1` refuses one under that
  # name), so the registry test is also what keeps such a send out; an
  # unregistered target is `Routes.unregistered/2`'s finding, not this.
  @spec unqueued(Config.t(), Machine.t()) :: [route_finding()]
  defp unqueued(
         %Config{timer_queue: nil, send_type: send_type, route_adapters: adapters},
         %Machine{contents: contents}
       )
       when is_binary(send_type) do
    for %Content.Send{type: {:static, ^send_type}, target: {:static, route}, delay: {:static, _}} =
          node <- Tuple.to_list(contents),
        Map.has_key?(adapters, route),
        do: %{route: route, location: node.location, reason: :no_timer_queue}
  end

  defp unqueued(%Config{}, %Machine{}), do: []

  # One compiled executable-content node. Only an execution-target
  # `<send>` of this configuration's literal type is looked at.
  @spec classify(Config.t(), lookup(), Content.t(), report()) :: report()
  defp classify(%Config{send_type: send_type}, lookup, %Content.Send{} = node, acc)
       when is_binary(send_type) do
    if node.type == {:static, send_type} and
         node.target == {:static, SendHandler.execution_target()},
       do: judge_send(lookup, node, acc),
       else: acc
  end

  defp classify(%Config{}, _lookup, _node, acc), do: acc

  @spec judge_send(lookup(), Content.Send.t(), report()) :: report()
  defp judge_send(lookup, %Content.Send{} = node, acc) do
    with {:ok, event} <- literal_event(node),
         {:ok, document} <- literal_document(node) do
      case delivery_reason(lookup, node, document, event) do
        nil ->
          acc

        reason ->
          add(acc, :undeclared, %{
            event: event,
            document: document,
            location: node.location,
            reason: reason
          })
      end
    else
      {:unchecked, reason} -> add(acc, :unchecked, %{reason: reason, location: node.location})
    end
  end

  # ADR-0008's 2026-09-23 Amendment: a delayed send (a `delay` or a
  # `delayexpr`) to the execution target is never delivered, so it is a
  # finding of its own and the lookup is not asked.
  @spec delivery_reason(lookup(), Content.Send.t(), String.t(), String.t()) :: reason() | nil
  defp delivery_reason(_lookup, %Content.Send{delay: delay}, _document, _event)
       when delay != nil,
       do: :delay

  defp delivery_reason(lookup, %Content.Send{}, document, event),
    do: judge(lookup, document, event)

  @spec literal_event(Content.Send.t()) ::
          {:ok, String.t()} | {:unchecked, :eventexpr | :no_event}
  defp literal_event(%Content.Send{event: {:static, event}}) when is_binary(event),
    do: {:ok, event}

  defp literal_event(%Content.Send{event: {:compiled, _compiled, _source}}),
    do: {:unchecked, :eventexpr}

  defp literal_event(%Content.Send{}), do: {:unchecked, :no_event}

  # ADR-0008, decision 1: exactly one `<param>` named `document`, no
  # `namelist` entry of that name, written as `expr`, compiling to the one
  # instruction `["lit", value]` with `value` a non-empty string.
  @spec literal_document(Content.Send.t()) ::
          {:ok, String.t()} | {:unchecked, :document_expr | :no_document}
  defp literal_document(%Content.Send{params: params, namelist: namelist}) do
    case {named_document(params), named_document(namelist)} do
      {[], []} -> {:unchecked, :no_document}
      {[param], []} -> literal_param(param)
      _more -> {:unchecked, :document_expr}
    end
  end

  defp named_document(params), do: Enum.filter(params, &match?(%Param{name: "document"}, &1))

  @spec literal_param(Param.t()) :: {:ok, String.t()} | {:unchecked, :document_expr}
  defp literal_param(%Param{
         kind: :expr,
         expr: {:compiled, %Predicator.Compiled{instructions: [["lit", value]]}, _source}
       })
       when is_binary(value) and value != "",
       do: {:ok, value}

  defp literal_param(%Param{}), do: {:unchecked, :document_expr}

  # The one relation for both sends and bindings (ADR-0008, decisions 2
  # and 4): nil when the receiver accepts `event`, else the reason.
  @spec judge(lookup(), String.t(), String.t()) :: reason() | nil
  defp judge(lookup, document, event) do
    case lookup.(document) do
      {:ok, names} when is_list(names) ->
        if event in names, do: nil, else: :undeclared

      {:ok, :undeclared, %Machine{} = machine} ->
        case Statifier.Chart.check_accepts(machine, [event]) do
          %{unreachable: []} -> nil
          %{unreachable: _unreachable} -> :undeclared_by_computed_set
        end

      {:error, :not_published} ->
        :not_published

      other ->
        raise ArgumentError,
              "the lookup answered #{inspect(other)} for #{inspect(document)}; expected " <>
                "{:ok, names}, {:ok, :undeclared, machine} or {:error, :not_published}"
    end
  end

  @spec add(report(), :undeclared | :unchecked, finding() | unchecked()) :: report()
  defp add(acc, key, entry), do: Map.update!(acc, key, &[entry | &1])
end
