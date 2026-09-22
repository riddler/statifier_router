defmodule StatifierRouter.Delivery do
  @moduledoc """
  The delivery module `StatifierRouter.Config` names by default: one
  binding's delivery of one event, as one transaction on the host's repo
  (ADR-0003, section 1).

  `deliver/4` is the seam `StatifierRouter.route/3` calls. It reads five
  options of the configuration, four of them required:

    * `:store` - the `%StatifierPersistence.Storage{}` executions are kept
      in. It must be built over the configuration's own `:repo`, so that
      `StatifierPersistence.Executions.create/4` and
      `StatifierPersistence.Executions.step/5` write through the delivery's
      transaction rather than opening their own (statifier_persistence's
      README, "Writing inside a caller's transaction").
    * `:executor` - the `StatifierPersistence.Executor` both doors hand
      their effects to.
    * `:resolver` - the `StatifierRouter.Resolver`, a module or an
      arity-2 fun, answering `{content_hash, machine}` or
      `{:error, reason}` for `(scope, document)`: the chart a new
      execution of `document` starts on (ADR-0002, section 4). It is
      called only when the delivery is about to create an execution.
      The `content_hash` it answers is not carried anywhere: the machine
      is handed on, and statifier_persistence records the hash
      `Statifier.Machine.identity/1` derives from that machine, which is
      the hash `:chart_resolver` is later asked for (ADR-0002, the
      2026-09-20 Note).
    * `:chart_resolver` - `(content_hash) -> {:ok, machine}` or `:error`:
      the compiled chart an existing execution started on, which `step/5`
      is handed. An existing execution keeps the chart it started on, so
      this is looked up by the content hash its record carries, never by
      its document.
    * `:persistence_options` - the per-call snapshot options both doors
      carry, `:routes`, `:invoke_types` and `:send_types`. They reach a
      `step/5` beside the event and a `create/4` inside its
      `initialize:`: `Statifier.MachineState.new/2` is the one writer of
      the fields they set, and a create has no stored position to stamp
      (statifier_persistence's `create/4` option docs, at
      statifier_persistence 9cd192b; its own driver places
      `invoke_types:` the same way).

  ## What one delivery does

  The transaction first claims `(binding_id, message_id)` with
  `StatifierRouter.Dedupe.claim/4`, its first write under every `create`
  mode. When the pair's row is present and unexpired, the delivery is a
  duplicate, and the transaction writes the ledger row and nothing else:
  no address row is read or written (ADR-0003, section 6). Past the claim,
  the binding's `create` decides the rest (ADR-0003, section 4):

    * `:if_absent` reads the address row for `(scope, document, key)`.
      When there is none, it mints an execution id and inserts the row
      with it, an insert that inserts nothing on a conflict with the
      unique index and does not fail the transaction; when it inserted
      nothing, another delivery's row won the race, and a following
      statement reads that row (ADR-0003, section 3). For the row it
      inserted, it asks the resolver for the chart and calls `create/4`
      under the minted id; for a row it read, it reads the execution's
      status.
    * `:never` reads the address row and never inserts one. When there is
      none, the outcome is `{:dropped, binding_id, :no_execution}`:
      nothing is created or stepped, and the ledger row and the claim's
      dedupe row are the delivery's only writes. For a row it read, it
      reads the execution's status, as `:if_absent` does.
    * `:always_new` neither reads nor writes an address row (ADR-0002,
      section 7). It mints an execution id, asks the resolver for the
      chart and calls `create/4` under that id, for every delivery; the
      minted id is the only handle on the execution.

  Then it calls `step/5` with the event, unless the execution is
  terminal, writes the ledger row (ADR-0004, section 4) and commits.

  The outcomes are `{:created_and_delivered, binding_id, execution_id}`
  when this delivery created the execution, `{:delivered, binding_id,
  execution_id}` when it stepped one that existed, `{:duplicate,
  binding_id}` when the claim found the pair already handled,
  `{:dropped, binding_id, :no_execution}` for a `:never` binding whose
  address has no row, and `{:dropped, binding_id, :finished}` when the
  execution was terminal: read terminal before the step, created already
  terminal, or answered `{:discarded, execution}` by `step/5` (ADR-0004,
  section 3). A terminal sighting through an address row stamps the row's
  `terminal_seen_at` when it is still empty (ADR-0002, section 5); the
  row itself is left in place, and removing it is
  `StatifierRouter.Addresses.reap/2`'s. Every outcome but the duplicate
  commits the dedupe row the claim wrote, a drop included, and a
  duplicate's ledger row carries the key and no execution id (ADR-0004,
  section 4).

  Nothing here writes the input log: `step/5` appends the event it steps
  (ADR-0003, section 1).

  ## What a route may not do while a delivery runs

  A route called at the executor seam runs inside this transaction, under
  the execution's lock, and ADR-0005 decision 5 forbids it to call back
  into the sending execution: a nested step would run from the position
  the outer step has not written yet and would then be overwritten by it.
  `deliver/4` refuses while `StatifierRouter.SendHandler.sending_execution/0`
  names an execution, answering
  `{:error, {:reentrant_route, execution_id}}` before it opens anything,
  so a route that calls `StatifierRouter.route/3` steps nothing and writes
  nothing. A route that calls
  `StatifierPersistence.Executions.step/5` directly reaches past this
  door; the record forbids that call and this package has no guard for it.

  The scope a delivery runs under is also set for the length of the call,
  because the executor seam's context carries an execution id and a
  content hash and no scope, and a per-scope route override needs one.
  The seam runs in this same process, inside this transaction.

  An `{:error, reason}` from `create/4`, `step/5` or
  `StatifierPersistence.Storage.fetch_execution/2`,
  `{:error, {:unresolved_document, document, reason}}` when the resolver
  answers `{:error, reason}`, and
  `{:error, {:chart_not_resolved, content_hash}}` when the chart resolver
  answers `:error`, roll the whole transaction back and are returned. A
  raise rolls it back the same way and propagates; nothing here rescues
  it. Effects the executor was handed before a rollback stay fired
  (ADR-0003, section 2).

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
  alias StatifierRouter.Dedupe
  alias StatifierRouter.Resolver
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.SendHandler

  @terminal [:completed, :failed, :cancelled]

  @doc """
  Delivers one event for one binding under `key`, as the module
  documentation describes, and answers with the outcome or
  `{:error, reason}`.
  """
  @spec deliver(Config.t(), Binding.t(), String.t(), StatifierRouter.delivery()) ::
          StatifierRouter.outcome() | {:error, term()}
  def deliver(%Config{} = config, %Binding{} = binding, key, delivery) do
    case SendHandler.sending_execution() do
      nil -> delivered(config, binding, key, delivery)
      execution_id -> {:error, {:reentrant_route, execution_id}}
    end
  end

  defp delivered(config, binding, key, delivery) do
    SendHandler.put_delivery_scope(delivery.scope)

    config.repo.transaction(fn ->
      case claimed(config, binding, key, delivery) do
        {:ok, outcome} -> outcome
        {:error, reason} -> config.repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} = error -> error
    end
  after
    SendHandler.delete_delivery_scope()
  end

  # The claim is the transaction's first write under every create mode: a
  # duplicate touches nothing past it (ADR-0003, sections 1 and 6).
  defp claimed(config, binding, key, delivery) do
    case Dedupe.claim(config, binding, delivery.message_id, delivery.now) do
      :new -> by_mode(config, binding, key, delivery)
      :duplicate -> duplicate(config, binding, key, delivery)
    end
  end

  defp by_mode(config, %Binding{create: :always_new} = binding, key, delivery),
    do: create(config, binding, key, delivery, mint_execution_id(), nil)

  defp by_mode(config, binding, key, delivery) do
    case lookup(config, delivery.scope, binding.document, key) do
      %Address{} = row -> existing(config, binding, key, delivery, row)
      nil -> absent(config, binding, key, delivery)
    end
  end

  defp absent(config, %Binding{create: :never} = binding, key, delivery) do
    record(config, binding, key, delivery, "dropped: no_execution", nil)
    {:ok, {:dropped, binding.id, :no_execution}}
  end

  defp absent(config, %Binding{create: :if_absent} = binding, key, delivery),
    do: insert_or_existing(config, binding, key, delivery)

  defp duplicate(config, binding, key, delivery) do
    record(config, binding, key, delivery, "duplicate", nil)
    {:ok, {:duplicate, binding.id}}
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
        create(config, binding, key, delivery, inserted.execution_id, inserted)
    end
  end

  # `row` is the address row the execution id was written to, or nil under
  # :always_new, which writes none (ADR-0002, section 7).
  defp create(config, binding, key, delivery, execution_id, row) do
    with {:ok, machine} <- resolve(config, delivery.scope, binding.document),
         {:ok, execution, _state} <-
           Executions.create(config.store, execution_id, machine, create_options(config)) do
      if execution.status in @terminal do
        finished(config, binding, key, delivery, execution_id, row)
      else
        step(config, binding, key, delivery, {execution_id, row}, machine, :created_and_delivered)
      end
    end
  end

  defp existing(config, binding, key, delivery, row) do
    case Storage.fetch_execution(config.store, row.execution_id) do
      {:ok, %{status: status}} when status in @terminal ->
        finished(config, binding, key, delivery, row.execution_id, row)

      {:ok, record} ->
        with {:ok, machine} <- chart(config, record.content_hash) do
          step(config, binding, key, delivery, {row.execution_id, row}, machine, :delivered)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp step(config, binding, key, delivery, {execution_id, row}, machine, outcome) do
    event = Event.external(delivery.name, data: delivery.data)

    case Executions.step(config.store, execution_id, machine, event, step_options(config)) do
      {:ok, _execution, _state} ->
        record(config, binding, key, delivery, Atom.to_string(outcome), execution_id)
        {:ok, {outcome, binding.id, execution_id}}

      {:discarded, _execution} ->
        finished(config, binding, key, delivery, execution_id, row)

      {:error, _reason} = error ->
        error
    end
  end

  defp finished(config, binding, key, delivery, execution_id, row) do
    if row, do: stamp_terminal_seen(config, row, delivery.now)
    record(config, binding, key, delivery, "dropped: finished", execution_id)
    {:ok, {:dropped, binding.id, :finished}}
  end

  # The two doors take the snapshot in different places, and a helper that
  # treated them as one shape would leave a created execution without the
  # host's types for its whole life: on `create/4` the snapshot travels
  # inside `initialize:`, on `step/5` beside the event.
  defp create_options(config),
    do: [executor: config.executor, initialize: config.persistence_options]

  defp step_options(config),
    do: [{:executor, config.executor} | config.persistence_options]

  defp resolve(config, scope, document) do
    case Resolver.call(config.resolver, scope, document) do
      {content_hash, %Machine{} = machine} when is_binary(content_hash) ->
        {:ok, machine}

      {:error, reason} ->
        {:error, {:unresolved_document, document, reason}}

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
