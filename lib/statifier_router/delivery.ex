defmodule StatifierRouter.Delivery do
  @moduledoc """
  The delivery module `StatifierRouter.Config` names by default: one
  binding's delivery of one event, as one transaction on the host's repo
  (ADR-0003, section 1).

  `deliver/4` is the seam `StatifierRouter.route/3` calls. It reads four
  options of the configuration:

    * `:store` - the `%StatifierPersistence.Storage{}` executions are kept
      in. It must be built over the configuration's own `:repo`, so that
      `StatifierPersistence.Executions.create/4` and
      `StatifierPersistence.Executions.step/5` write through the delivery's
      transaction rather than opening their own (statifier_persistence's
      README, "Writing inside a caller's transaction").
    * `:executor` - the `StatifierPersistence.Executor` both doors hand
      their effects to.
    * `:resolver` - `(scope, document) -> {content_hash, machine}` or
      `{:error, reason}`: the chart a new execution of `document` starts
      on (ADR-0002, section 4). It is called only when the delivery is
      about to create an execution.
    * `:chart_resolver` - `(content_hash) -> {:ok, machine}` or `:error`:
      the compiled chart an existing execution started on, which `step/5`
      is handed. An existing execution keeps the chart it started on, so
      this is looked up by the content hash its record carries, never by
      its document.

  ## What one delivery does

  Under a binding whose `create` is `:if_absent`, the transaction:

    1. reads the address row for `(scope, document, key)`;
    2. when there is none, mints an execution id and inserts the row with
       it, an insert that inserts nothing on a conflict with the unique
       index and does not fail the transaction; when it inserted nothing,
       another delivery's row won the race, and a following statement
       reads that row (ADR-0003, section 3);
    3. for the row it inserted, asks the resolver for the chart and calls
       `create/4` under the minted id; for a row it read, reads the
       execution's status;
    4. calls `step/5` with the event, unless the execution is terminal;
    5. writes the ledger row (ADR-0004, section 4) and commits.

  The outcomes are `{:created_and_delivered, binding_id, execution_id}`
  when this delivery created the execution, `{:delivered, binding_id,
  execution_id}` when it stepped one that existed, and
  `{:dropped, binding_id, :finished}` when the execution was terminal:
  read terminal before the step, created already terminal, or answered
  `{:discarded, execution}` by `step/5` (ADR-0004, section 3). A terminal
  sighting stamps the address row's `terminal_seen_at` when it is still
  empty (ADR-0002, section 5).

  Nothing here writes the input log: `step/5` appends the event it steps
  (ADR-0003, section 1).

  An `{:error, reason}` from the resolver, from `create/4`, `step/5` or
  `StatifierPersistence.Storage.fetch_execution/2`, and
  `{:error, {:chart_not_resolved, content_hash}}` when the chart resolver
  answers `:error`, roll the whole transaction back and are returned. A
  raise rolls it back the same way and propagates; nothing here rescues
  it. Effects the executor was handed before a rollback stay fired
  (ADR-0003, section 2).

  Under `:never` and `:always_new` this release answers
  `{:error, :not_implemented}` and writes nothing.

  The execution id is a UXID with the prefix `ex`, minted by
  `UXID.generate!/1`; nothing is derived from the address (ADR-0002,
  section 3).
  """

  import Ecto.Query, only: [from: 2]

  alias Statifier.Event
  alias Statifier.Machine
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Ledger

  @terminal [:completed, :failed, :cancelled]

  @doc """
  Delivers one event for one binding under `key`, as the module
  documentation describes, and answers with the outcome or
  `{:error, reason}`.
  """
  @spec deliver(Config.t(), Binding.t(), String.t(), StatifierRouter.delivery()) ::
          StatifierRouter.outcome() | {:error, term()}
  def deliver(%Config{} = config, %Binding{create: :if_absent} = binding, key, delivery) do
    config.repo.transaction(fn ->
      case if_absent(config, binding, key, delivery) do
        {:ok, outcome} -> outcome
        {:error, reason} -> config.repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} = error -> error
    end
  end

  def deliver(%Config{}, %Binding{create: mode}, _key, _delivery)
      when mode in [:never, :always_new],
      do: {:error, :not_implemented}

  defp if_absent(config, binding, key, delivery) do
    case lookup(config, delivery.scope, binding.document, key) do
      %Address{} = row -> existing(config, binding, key, delivery, row)
      nil -> insert_or_existing(config, binding, key, delivery)
    end
  end

  defp insert_or_existing(config, binding, key, delivery) do
    row = %Address{
      scope: delivery.scope,
      document: binding.document,
      key: key,
      execution_id: mint_execution_id(),
      inserted_at: delivery.now
    }

    case config.repo.insert!(Config.put_meta(config, row),
           on_conflict: :nothing,
           conflict_target: [:scope, :document, :key]
         ) do
      %Address{id: nil} ->
        # The race's loser: the winner's row is committed, and this
        # statement, not the insert, is what reads it (ADR-0003, section 3).
        winner = lookup!(config, delivery.scope, binding.document, key)
        existing(config, binding, key, delivery, winner)

      %Address{} = inserted ->
        create(config, binding, key, delivery, inserted)
    end
  end

  defp create(config, binding, key, delivery, row) do
    with {:ok, machine} <- resolve(config, delivery.scope, binding.document),
         {:ok, execution, _state} <-
           Executions.create(config.store, row.execution_id, machine, executor: config.executor) do
      if execution.status in @terminal do
        finished(config, binding, key, delivery, row)
      else
        step(config, binding, key, delivery, row, machine, :created_and_delivered)
      end
    end
  end

  defp existing(config, binding, key, delivery, row) do
    case Storage.fetch_execution(config.store, row.execution_id) do
      {:ok, %{status: status}} when status in @terminal ->
        finished(config, binding, key, delivery, row)

      {:ok, record} ->
        with {:ok, machine} <- chart(config, record.content_hash) do
          step(config, binding, key, delivery, row, machine, :delivered)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp step(config, binding, key, delivery, row, machine, outcome) do
    event = Event.external(delivery.name, data: delivery.data)

    case Executions.step(config.store, row.execution_id, machine, event,
           executor: config.executor
         ) do
      {:ok, _execution, _state} ->
        record(config, binding, key, delivery, Atom.to_string(outcome), row.execution_id)
        {:ok, {outcome, binding.id, row.execution_id}}

      {:discarded, _execution} ->
        finished(config, binding, key, delivery, row)

      {:error, _reason} = error ->
        error
    end
  end

  defp finished(config, binding, key, delivery, row) do
    stamp_terminal_seen(config, row, delivery.now)
    record(config, binding, key, delivery, "dropped: finished", row.execution_id)
    {:ok, {:dropped, binding.id, :finished}}
  end

  defp resolve(config, scope, document) do
    case config.resolver.(scope, document) do
      {content_hash, %Machine{} = machine} when is_binary(content_hash) ->
        {:ok, machine}

      {:error, _reason} = error ->
        error

      other ->
        raise ArgumentError,
              "the resolver answered #{inspect(other)} for #{inspect({scope, document})}; " <>
                "expected {content_hash, machine} or {:error, reason}"
    end
  end

  defp chart(config, content_hash) do
    case config.chart_resolver.(content_hash) do
      {:ok, %Machine{} = machine} ->
        {:ok, machine}

      :error ->
        {:error, {:chart_not_resolved, content_hash}}

      other ->
        raise ArgumentError,
              "the chart resolver answered #{inspect(other)} for #{inspect(content_hash)}; " <>
                "expected {:ok, machine} or :error"
    end
  end

  defp lookup(config, scope, document, key),
    do: config.repo.one(address_query(config, scope, document, key))

  defp lookup!(config, scope, document, key),
    do: config.repo.one!(address_query(config, scope, document, key))

  defp address_query(config, scope, document, key) do
    from(a in Config.queryable(config, Address),
      where: a.scope == ^scope and a.document == ^document and a.key == ^key
    )
  end

  # Stamped only while empty, so the horizon counts from the first
  # sighting (ADR-0002, section 5).
  defp stamp_terminal_seen(config, %Address{id: id}, now) do
    from(a in Config.queryable(config, Address),
      where: a.id == ^id and is_nil(a.terminal_seen_at)
    )
    |> config.repo.update_all(set: [terminal_seen_at: now])
  end

  defp record(config, binding, key, delivery, outcome, execution_id) do
    row = %Ledger{
      binding_id: binding.id,
      message_id: delivery.message_id,
      scope: delivery.scope,
      outcome: outcome,
      key: key,
      execution_id: execution_id,
      reason: nil,
      inserted_at: delivery.now
    }

    config.repo.insert!(Config.put_meta(config, row))
  end

  defp mint_execution_id, do: UXID.generate!(prefix: "ex")
end
