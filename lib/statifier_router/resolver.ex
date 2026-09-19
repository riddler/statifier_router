defmodule StatifierRouter.Resolver do
  @moduledoc """
  The host's answer to which chart a new execution of a document starts on
  (ADR-0002, section 4).

  This package keeps no publish store, so it cannot know which revision of
  a document is active. The host can. A resolver takes `(scope, document)`
  and answers `{content_hash, machine}`: the compiled machine of the chart
  new executions of that document start on under that scope, and that
  chart's content hash. `StatifierRouter.Delivery` calls it only when it is
  about to create an execution. An existing execution keeps the chart it
  started on and is never resolved through here: its chart is the
  configuration's `:chart_resolver`, looked up by the content hash its
  execution record carries (ADR-0002, the Amendment at its foot).

  A resolver is a module implementing this behaviour, the documented form,
  or an arity-2 fun with `c:resolve/2`'s own signature, accepted wherever a
  module is. A host with a publish store (a blocks document store, a
  database table of published revisions) implements `c:resolve/2` over it:

      defmodule MyApp.PublishedCharts do
        @behaviour StatifierRouter.Resolver

        @impl StatifierRouter.Resolver
        def resolve(scope, document) do
          case MyApp.Publishing.active_revision(scope, document) do
            {:ok, revision} ->
              machine = MyApp.Publishing.compiled_chart(revision)
              {Statifier.Machine.identity(machine).content_hash, machine}

            :error ->
              {:error, :not_published}
          end
        end
      end

  A host whose charts are compiled at boot can use
  `StatifierRouter.Resolver.Static` instead of writing one.

  The content hash answered is the one statifier_persistence records for
  the execution: the `content_hash` of `Statifier.Machine.identity/1` of
  the machine answered. `StatifierRouter.Delivery` hands the machine to
  `StatifierPersistence.Executions.create/4`, and statifier_persistence
  takes the hash it records from the machine itself.

  An `{:error, reason}` answer means the host has no chart for the
  document. The delivery's transaction rolls back and `StatifierRouter.route/3`
  returns `{:error, {:unresolved_document, document, reason}}`: nothing is
  created and no row is written (ADR-0003, section 1), and the error is not
  an outcome, so it has no ledger row (ADR-0004, section 7).
  """

  alias Statifier.Machine

  @typedoc "What a resolver answers."
  @type result :: {content_hash :: String.t(), Machine.t()} | {:error, term()}

  @typedoc """
  A resolver: a module implementing this behaviour, or an arity-2 fun with
  `c:resolve/2`'s own signature.
  """
  @type t :: module() | (scope :: String.t(), document :: String.t() -> result())

  @doc """
  The chart new executions of `document` start on under `scope`, as
  `{content_hash, machine}`, or `{:error, reason}` when the host has none.
  """
  @callback resolve(scope :: String.t(), document :: String.t()) :: result()

  # Package-internal: normalizes the module-or-fun shapes of t:t/0 into one
  # call. StatifierRouter.Delivery is the only intended caller.
  @doc false
  @spec call(t(), String.t(), String.t()) :: result()
  def call(resolver, scope, document) when is_atom(resolver),
    do: resolver.resolve(scope, document)

  def call(resolver, scope, document) when is_function(resolver, 2),
    do: resolver.(scope, document)

  # Package-internal: whether `value` is one of t:t/0's shapes. A module
  # must be loadable and export resolve/2.
  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_function(value, 2), do: true

  def valid?(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Code.ensure_loaded?(value) and function_exported?(value, :resolve, 2)

  def valid?(_value), do: false
end
