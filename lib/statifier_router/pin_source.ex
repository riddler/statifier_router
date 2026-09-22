defmodule StatifierRouter.PinSource do
  @moduledoc """
  The address table's vote on a chart retirement:
  `StatifierPersistence.PinSource` implemented over the address rows.

  `StatifierPersistence.Executions.retire_chart/4` counts the pins it can
  see itself and asks the host's pin sources for the ones it cannot. An
  address row is one it cannot: it lives in this package's table, in a
  package statifier_persistence does not depend on, and it is the reason
  a later event still reaches the execution it names (ADR-0002,
  section 1). A retirement taken while such a row stands would leave that
  event routed to an execution whose chart is gone.

  ## What the count is

  `%{addresses: n}`, where `n` is the number of address rows naming one of
  the executions in the context. The context's `:execution_ids` are the
  ids of the `:active` executions on the content hash, which the retire
  call has already read, and that is the only handle this source needs: an
  address row carries an `execution_id` and no content hash, so a source
  over this table can answer for a hash it cannot see. The content hash is
  therefore not read here.

  No horizon is applied to the count. The horizon in
  `StatifierRouter.Addresses.reap/2` runs from `terminal_seen_at`, which is
  stamped only once this package has seen the row's execution terminal, so
  a row naming an `:active` execution has no horizon running against it
  yet. The rows this source counts are live addresses by construction.

  So the pin releases exactly when the address it stands for is gone: the
  execution finishes, the reaper stamps the row terminal and deletes it
  once the horizon has elapsed, and the next retire call counts one pin
  fewer. Nothing here retains a row, and nothing here deletes one.

  ## How a host installs it

  The behaviour's callback takes a content hash and a context and nothing
  else, so the configuration this source reads the table through has to be
  bound into the module. `use StatifierRouter.PinSource` writes that
  module, with `:config` an expression it evaluates on every call:

      defmodule MyApp.RouterPins do
        use StatifierRouter.PinSource, config: MyApp.Router.config()
      end

  `MyApp.Router.config/0` is the host's own: the same
  `%StatifierRouter.Config{}` it routes events with. The host then names
  the module at the retire call:

      StatifierPersistence.Executions.retire_chart(store, content_hash, [MyApp.RouterPins])

  A host that would rather not `use` a macro writes the same module by
  hand against `StatifierPersistence.PinSource` and delegates to
  `count/2` from its own `pins/2`.

  ## A source that cannot answer raises

  `StatifierPersistence.PinSource` makes raising the way to say "I could
  not answer", because a source that answers zero when it does not know
  retires a pinned chart. This one keeps that: a context without
  `:execution_ids`, or a configuration that is not a
  `%StatifierRouter.Config{}`, raises rather than counting nothing, and
  `StatifierPersistence.PinSource.collect/3` turns the raise into
  `{:error, {module, {:raised, exception}}}`. A read that the repo itself
  refuses raises for the same reason and reaches the caller the same way.
  """

  import Ecto.Query, only: [from: 2]

  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address

  @doc """
  Writes a `StatifierPersistence.PinSource` over the address table.

  Takes one option, `:config`, an expression evaluating to the
  `%StatifierRouter.Config{}` whose repo and table the rows are counted
  in. It is evaluated on every call, so a host whose configuration is
  built at run time passes the call that builds it.
  """
  defmacro __using__(opts) do
    config = Keyword.fetch!(opts, :config)

    quote do
      @behaviour StatifierPersistence.PinSource

      @impl StatifierPersistence.PinSource
      def pins(_content_hash, context),
        do: StatifierRouter.PinSource.count(unquote(config), context)
    end
  end

  @doc """
  The address rows under `config` naming one of the executions in
  `context`, as `%{addresses: n}`.

  This is what a module written by `use StatifierRouter.PinSource` answers
  with. It raises for a context carrying no `:execution_ids`, which is the
  refusal `StatifierPersistence.PinSource` asks a source for.
  """
  @spec count(Config.t(), StatifierPersistence.PinSource.context()) :: %{
          addresses: non_neg_integer()
        }
  def count(%Config{} = config, %{execution_ids: execution_ids})
      when is_list(execution_ids) do
    %{addresses: addresses(config, execution_ids)}
  end

  # An empty list of active executions has no rows to count and is not
  # worth a round trip: `where: a.execution_id in ^[]` is already known to
  # match nothing.
  defp addresses(_config, []), do: 0

  defp addresses(config, execution_ids) do
    config.repo.aggregate(
      from(a in Config.queryable(config, Address), where: a.execution_id in ^execution_ids),
      :count
    )
  end
end
