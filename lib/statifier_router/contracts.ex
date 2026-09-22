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

  ## The three reasons

  A finding carries `reason`, which says which contract refused it
  (ADR-0008, decisions 2 and 4):

  - `:undeclared` - the receiver declares names and this is not one.
  - `:undeclared_by_computed_set` - the receiver declares nothing, and no
    reachable transition of its chart matches this name.
  - `:not_published` - the lookup answered `{:error, :not_published}`.

  ## What cannot be checked

  Only a literal can be judged. A send `undeclared_events/3` selects but
  cannot judge is never a finding and never passed silently: it is
  reported under `:unchecked` as `%{reason: reason, location: location}`,
  the shape `StatifierRouter.Routes.unregistered/2`'s own unchecked
  entries have (ADR-0008, decision 3). The reasons are `:eventexpr`,
  `:no_event`, `:document_expr` and `:no_document`; see `t:unchecked/0`.
  A send whose `type` or `target` is an expression is not selected here
  at all: `StatifierRouter.Routes.unregistered/2` reports it, and
  `check/3` carries that list once.

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

  @typedoc "Which contract refused a name; see the moduledoc."
  @type reason :: :undeclared | :undeclared_by_computed_set | :not_published

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
  accept: the event, the receiving document, the `<send>` element's
  location and the reason.
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
          reason: reason()
        }

  @typedoc "What `check/3` answers; see its `@doc`."
  @type check_report :: %{
          unsupported_types: [Statifier.Send.Types.unsupported_send()],
          unregistered_routes: [Routes.finding()],
          unchecked: [Routes.unchecked() | unchecked()],
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
  - `:unregistered_routes` - the `:unregistered` list of
    `StatifierRouter.Routes.unregistered/2`.
  - `:unchecked` - the unchecked entries of
    `StatifierRouter.Routes.unregistered/2` (`:typeexpr`, `:targetexpr`)
    and of `undeclared_events/3` together, in document order, ordered by
    each `<send>` element's source offset.
  - `:undeclared_events` - the findings of `undeclared_events/3`.
  - `:undeclared_binding_events` - `undeclared_binding_events/2` over the
    configuration's `:bindings`.

  Both route functions are composed unchanged. A finding under either
  `:undeclared_events` or `:undeclared_binding_events` carries one of the
  three reasons, `:undeclared`, `:undeclared_by_computed_set` (the
  receiver declares nothing and `Statifier.Chart.check_accepts/2` finds
  no reachable transition for the name) or `:not_published`. Every
  `:unchecked` entry is `%{reason, location}`, its reason one of
  `:typeexpr`, `:targetexpr`, `:eventexpr`, `:no_event`, `:document_expr`
  or `:no_document`. Which finding blocks a publish is the host's
  decision.
  """
  @spec check(Config.t(), Machine.t(), lookup()) :: check_report()
  def check(%Config{} = config, %Machine{} = machine, lookup) when is_function(lookup, 1) do
    routes = Routes.unregistered(config, machine)
    events = undeclared_events(config, machine, lookup)

    %{
      unsupported_types: Routes.unsupported_types(config, machine),
      unregistered_routes: routes.unregistered,
      unchecked: Enum.sort_by(routes.unchecked ++ events.unchecked, & &1.location.start_offset),
      undeclared_events: events.undeclared,
      undeclared_binding_events: undeclared_binding_events(config.bindings, lookup)
    }
  end

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
      case judge(lookup, document, event) do
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
