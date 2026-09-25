defmodule StatifierRouter.Delivery do
  @moduledoc """
  The delivery module `StatifierRouter.Config` names by default: one
  binding's delivery of one event, as one transaction on the host's repo
  (ADR-0003, section 1).

  It has two doors onto one transaction. `deliver/4` is the seam
  `StatifierRouter.route/3` calls for a binding, and `deliver_event/4` the
  one `StatifierRouter.SendHandler` calls for an execution-to-execution
  send (ADR-0006, section 2), which brings its own event and its own
  idempotency key and is otherwise settled here exactly as a binding's
  delivery is.

  `deliver/4` reads five options of the configuration, four of them
  required:

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
  section 3). A binding's delivery whose `step/5` took the event and
  selected no transition for it - the state `step/5` answers carries
  `last_selection: :none` - is `{:dropped, binding_id, :unmatched_event}`,
  on the delivered path and on the created path alike, and its ledger
  row names the execution (ADR-0004, the Note of 2026-09-25). The
  execution's input log holds the event all the same, because `step/5`
  appended it. `deliver_event/4` does not take this outcome: a send the
  receiving execution does not take is delivered or created_and_delivered
  as before. A terminal sighting through an address row stamps the row's
  `terminal_seen_at` when it is still empty (ADR-0002, section 5); the
  row itself is left in place, and removing it is
  `StatifierRouter.Addresses.reap/2`'s. Every outcome but the duplicate
  commits the dedupe row the claim wrote, a drop included, and a
  duplicate's ledger row carries the key and no execution id (ADR-0004,
  section 4).

  Nothing here writes the input log: `step/5` appends the event it steps
  (ADR-0003, section 1).

  ## The completion hook

  `StatifierRouter.Config`'s `:on_complete` names a registered route an
  execution's donedata is handed to on the delivery that finishes it. It
  fires from the call that produced the termination - the `create/4` or
  the `step/5` whose answer carries a terminal execution - and from no
  other, because that answer is the only place the donedata exists:
  `StatifierPersistence.Execution.from_record/1`'s own documentation says
  a stored record carries none (its ADR-0008 decision 3), so it sets the
  field to `nil` on every struct built from a row. A delivery to an
  execution that was already terminal answers
  `{:dropped, binding_id, :finished}` and never reaches the hook.

  The route is handed a `done.execution` event whose `data` is the
  donedata verbatim - `:undefined`, statifier's no-value marker, for a
  `<final>` that carries none - and whose `origin` is the execution id, under an idempotency key of that execution
  id, the counters the answering state reports, and no ordinal. It runs
  inside this delivery's transaction like any other route, and an
  `{:error, reason}` from it settles the delivery as
  `{:error, {:on_complete, route_name, reason}}`.

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
  answers `:error`, roll this delivery's writes back and are returned. Both
  doors do that the same way: the delivery runs inside an SQL savepoint of
  its own, an error rolls back to that savepoint, and the reason is
  returned as an ordinary value, with no `c:Ecto.Repo.rollback/1` anywhere
  (ADR-0003, the Amendment of 2026-09-23). When the door opened the
  transaction itself, that leaves it holding nothing of the delivery's,
  which is ADR-0003, section 1's guarantee; when it was called inside a
  caller's transaction, it undoes the delivery's writes and nothing of the
  caller's. `deliver_event/4`'s documentation says why a rollback cannot
  do this. A raise propagates; nothing here rescues it, and it takes an
  enclosing transaction with it. Effects the executor was handed before a
  rollback stay fired (ADR-0003, section 2).

  The execution id is a UXID with the prefix `ex`, minted by
  `UXID.generate!/1`; nothing is derived from the address (ADR-0002,
  section 3).
  """

  import Ecto.Query, only: [from: 2]

  alias Statifier.Event
  alias Statifier.Machine
  alias Statifier.MachineState
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

  # The name of the event `:on_complete` hands a route. A completion is not
  # a `<send>`, so no chart named it; it is written here once and the README
  # documents it.
  @done_event "done.execution"

  @typedoc """
  What one delivery settles, past the event itself: the name its ledger row
  and its dedupe claim are written under, the document its address names,
  the `create` mode a miss follows, and the dedupe horizon that claim uses.

  A `t:StatifierRouter.Binding.t/0` is one of these, and it is the one
  `deliver/4` builds. The other is ADR-0006's execution target: the
  reserved name `execution`, the `document` param the chart wrote, the
  `create` param it wrote, and ADR-0001, section 1's default horizon, since
  no binding supplies one there.
  """
  @type plan :: %{
          required(:id) => String.t(),
          required(:document) => String.t(),
          required(:create) => :if_absent | :never | :always_new,
          required(:dedupe) => %{by: :message_id, horizon_ms: pos_integer()},
          optional(atom()) => term()
        }

  @typedoc """
  The message one delivery carries: the event stepped into the execution,
  the id its dedupe row and its ledger row are written under, the scope it
  runs in and the time its rows carry.
  """
  @type envelope :: %{
          required(:event) => Event.t(),
          required(:message_id) => String.t(),
          required(:scope) => String.t(),
          required(:now) => DateTime.t(),
          optional(atom()) => term()
        }

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

  @doc """
  Delivers one prebuilt event under `plan`, in the same transaction and the
  same order `deliver/4` uses, and answers with the same outcomes.

  This is the door ADR-0006, section 2 names: an execution-to-execution
  send resolves its address, gets or creates its execution and writes its
  dedupe and ledger rows through this one function, so neither the unique
  index race nor the ledger has a second implementation here. Its caller
  owns three things `deliver/4` owns for a binding: it builds the event
  (ADR-0006, section 4 gives an execution-to-execution send the engine
  builder rather than `Statifier.Event.external/2`), it composes the
  `message_id`, and it decides whether a scope override is in force.
  `StatifierRouter.SendHandler` is that caller.

  The reentrancy refusal `deliver/4` opens with is not repeated here. It
  guards the route door, and an execution-to-execution send never enters a
  route: `StatifierRouter.SendHandler` branches on the reserved target name
  before it marks a route as running.

  ## This door takes a savepoint, and it does not roll back

  `deliver/4` settles the same way, for the same reason: `route/3` is
  usually the outermost transaction on its path, but nothing stops a host
  from calling it inside its own. This door is never outermost at the
  seam: it is called inside the sending execution's own `step/5`, which
  statifier_persistence has already opened a transaction for. A
  `c:Ecto.Repo.rollback/1` there would take the **sender's** transaction
  with it, answer a bare `:rollback` in place of the reason, and raise
  `DBConnection.ConnectionError` out of the sending step's persist tail. And
  `mode: :savepoint` does not prevent it: `DBConnection.transaction/3`
  ignores its options once the connection is already in a transaction
  (db_connection 2.10.2, the `conn_mode: :transaction` clause), so a nested
  `c:Ecto.Repo.transaction/2` gets no savepoint to roll back to.

  That outcome is the opposite of what the records require: ADR-0005,
  section 7 has the handler's `{:error, reason}` leave the sending step
  standing, and ADR-0006, section 3 rests on it. So this door rolls nothing
  back. It brackets the delivery in an explicit SQL savepoint of its own and
  answers the reason as an ordinary return:

    * on an outcome, the savepoint is released and the delivery's writes
      stand with the rest of the enclosing transaction;
    * on a delivery-level error - an unresolved document, a chart that does
      not resolve, a refusal from `create/4`, `step/5` or
      `StatifierPersistence.Storage.fetch_execution/2` - the transaction
      rolls back **to that savepoint**, which undoes every write this
      delivery made on the target side (the dedupe row it claimed, the
      address row it inserted, the execution it created) and nothing else,
      and `{:error, reason}` carrying the real reason is returned.

  The savepoint's name is minted from `System.unique_integer/1`, never from
  anything a caller supplies, and a nested delivery gets its own. The host's
  `:repo` therefore has to answer `query!/1` as well, which every
  `Ecto.Adapters.SQL` repo does; this package's tables are Postgres already.

  A raise is the one case that still reaches the enclosing transaction,
  exactly as it does on the binding path: nothing here rescues, and the
  record leaves a raise as a raise.
  """
  @spec deliver_event(Config.t(), plan(), String.t(), envelope()) ::
          StatifierRouter.outcome() | {:error, term()}
  def deliver_event(%Config{} = config, plan, key, %{event: %Event{}} = delivery),
    do: settled(config, "sr_execution_target_", plan, key, delivery)

  # The one way a delivery settles, on both doors. The transaction is what
  # gives the savepoint something to live in when the door is called
  # outside one; inside a caller's transaction - the sending step's at the
  # executor seam, or a host's own around `StatifierRouter.route/3` - it
  # nests, and the savepoint is the only thing that settles this delivery.
  # No `c:Ecto.Repo.rollback/1` anywhere: under a nested transaction it
  # would take the caller's transaction with it (`deliver_event/4`'s
  # documentation says why).
  defp settled(config, prefix, plan, key, delivery) do
    config.repo.transaction(fn -> guarded(config, prefix, plan, key, delivery) end)
    |> case do
      {:ok, {:ok, outcome}} -> outcome
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} = error -> error
    end
  end

  defp guarded(config, prefix, plan, key, delivery) do
    savepoint = prefix <> Integer.to_string(System.unique_integer([:positive]))
    config.repo.query!("SAVEPOINT " <> savepoint)

    case claimed(config, plan, key, delivery) do
      {:ok, outcome} ->
        config.repo.query!("RELEASE SAVEPOINT " <> savepoint)
        {:ok, outcome}

      {:error, _reason} = error ->
        config.repo.query!("ROLLBACK TO SAVEPOINT " <> savepoint)
        error
    end
  end

  defp delivered(config, %Binding{} = binding, key, delivery) do
    SendHandler.put_delivery_scope(delivery.scope)

    settled(
      config,
      "sr_delivery_",
      binding,
      key,
      Map.put(delivery, :event, Event.external(delivery.name, data: delivery.data))
    )
  after
    SendHandler.delete_delivery_scope()
  end

  # The claim is the transaction's first write under every create mode: a
  # duplicate touches nothing past it (ADR-0003, sections 1 and 6).
  defp claimed(config, plan, key, delivery) do
    case Dedupe.claim(config, plan, delivery.message_id, delivery.now) do
      :new -> by_mode(config, plan, key, delivery)
      :duplicate -> duplicate(config, plan, key, delivery)
    end
  end

  defp by_mode(config, %{create: :always_new} = plan, key, delivery),
    do: create(config, plan, key, delivery, mint_execution_id(), nil)

  defp by_mode(config, plan, key, delivery) do
    case lookup(config, delivery.scope, plan.document, key) do
      %Address{} = row -> existing(config, plan, key, delivery, row)
      nil -> absent(config, plan, key, delivery)
    end
  end

  defp absent(config, %{create: :never} = plan, key, delivery) do
    record(config, plan, key, delivery, "dropped: no_execution", nil)
    {:ok, {:dropped, plan.id, :no_execution}}
  end

  defp absent(config, %{create: :if_absent} = plan, key, delivery),
    do: insert_or_existing(config, plan, key, delivery)

  defp duplicate(config, plan, key, delivery) do
    record(config, plan, key, delivery, "duplicate", nil)
    {:ok, {:duplicate, plan.id}}
  end

  defp insert_or_existing(config, plan, key, delivery) do
    row = %Address{
      scope: delivery.scope,
      document: plan.document,
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
        winner = lookup!(config, delivery.scope, plan.document, key)
        existing(config, plan, key, delivery, winner)

      %Address{} = inserted ->
        create(config, plan, key, delivery, inserted.execution_id, inserted)
    end
  end

  # `row` is the address row the execution id was written to, or nil under
  # :always_new, which writes none (ADR-0002, section 7).
  defp create(config, plan, key, delivery, execution_id, row) do
    with {:ok, machine} <- resolve(config, delivery.scope, plan.document),
         {:ok, execution, state} <-
           Executions.create(config.store, execution_id, machine, create_options(config)),
         :ok <- complete(config, execution, state) do
      if execution.status in @terminal do
        finished(config, plan, key, delivery, execution_id, row)
      else
        step(config, plan, key, delivery, {execution_id, row}, machine, :created_and_delivered)
      end
    end
  end

  defp existing(config, plan, key, delivery, row) do
    case Storage.fetch_execution(config.store, row.execution_id) do
      {:ok, %{status: status}} when status in @terminal ->
        finished(config, plan, key, delivery, row.execution_id, row)

      {:ok, record} ->
        with {:ok, machine} <- chart(config, record.content_hash) do
          step(config, plan, key, delivery, {row.execution_id, row}, machine, :delivered)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp step(config, plan, key, delivery, {execution_id, row}, machine, outcome) do
    case Executions.step(
           config.store,
           execution_id,
           machine,
           delivery.event,
           step_options(config)
         ) do
      {:ok, execution, state} ->
        with :ok <- complete(config, execution, state) do
          taken(config, plan, key, delivery, execution_id, outcome, state)
        end

      {:discarded, _execution} ->
        finished(config, plan, key, delivery, execution_id, row)

      {:error, _reason} = error ->
        error
    end
  end

  # What a step that took the event records. A binding's delivery whose
  # event selected no transition is dropped: unmatched_event (ADR-0004, the
  # Note of 2026-09-25), read off the `last_selection` statifier stamps on
  # the state `step/5` answers; `:selected`, and `nil` (no round ran on
  # this event), keep the delivered or created_and_delivered outcome. The
  # execution target's door keeps its own outcomes: ADR-0006 settles what
  # a sender is told, and this record's Note does not reach it.
  defp taken(
         config,
         %Binding{} = plan,
         key,
         delivery,
         execution_id,
         _outcome,
         %MachineState{last_selection: :none}
       ) do
    record(config, plan, key, delivery, "dropped: unmatched_event", execution_id)
    {:ok, {:dropped, plan.id, :unmatched_event}}
  end

  defp taken(config, plan, key, delivery, execution_id, outcome, _state) do
    record(config, plan, key, delivery, Atom.to_string(outcome), execution_id)
    {:ok, {outcome, plan.id, execution_id}}
  end

  defp finished(config, plan, key, delivery, execution_id, row) do
    if row, do: stamp_terminal_seen(config, row, delivery.now)
    record(config, plan, key, delivery, "dropped: finished", execution_id)
    {:ok, {:dropped, plan.id, :finished}}
  end

  # The two doors take the snapshot in different places, and a helper that
  # treated them as one shape would leave a created execution without the
  # host's types for its whole life: on `create/4` the snapshot travels
  # inside `initialize:`, on `step/5` beside the event.
  defp create_options(config),
    do: [executor: config.executor, initialize: config.persistence_options]

  defp step_options(config),
    do: [{:executor, config.executor} | config.persistence_options]

  # `:on_complete`'s hook. It fires on the one call that produced the
  # termination and on no other, because that call's answer is the only
  # place the donedata exists: `StatifierPersistence.Execution.from_record/1`
  # sets `donedata` to `nil` on every struct built from a stored row, so a
  # hook that re-read the execution afterwards would hand a route `nil`
  # every time, with no error and no warning. A delivery to an execution
  # that was already terminal takes the `finished/6` path, which never
  # reaches here, so a finished execution's route is called once for the
  # completion and never again.
  #
  # The route is called inside this delivery's transaction, under the
  # execution's lock, like any other route. An `{:error, reason}` from it
  # is returned as this delivery's error rather than swallowed: the
  # sending execution is terminal and has no `error.communication`
  # transition left to take, so the only way a failed hand-off is not lost
  # is for the delivery to roll back and be redriven - which is what the
  # adapter's at-most-once obligation on the key is for.
  @spec complete(Config.t(), StatifierPersistence.Execution.t(), MachineState.t()) ::
          :ok | {:error, term()}
  defp complete(%Config{on_complete: nil}, _execution, _state), do: :ok

  defp complete(%Config{on_complete: name} = config, %{status: status} = execution, state)
       when status in @terminal do
    event =
      Event.external(@done_event, data: execution.donedata, origin: execution.execution_id)

    case SendHandler.deliver_to_route(
           config,
           name,
           execution.execution_id,
           event,
           {execution.execution_id, position(state), nil}
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:on_complete, name, reason}}
    end
  end

  defp complete(%Config{}, _execution, _state), do: :ok

  # A completion sits at no `<send>`, so the key's effect half is where in
  # the step the execution finished, read off the state the step answered:
  # the counters are the position's, and the three fields that belong to a
  # send element - its id, its content index and its owner - are empty. A
  # redriven step reaches the same counters from the same stored position,
  # so the key is stable across a redrive, which is what the route's
  # at-most-once obligation needs.
  @spec position(MachineState.t()) :: StatifierRouter.Route.position()
  defp position(%MachineState{} = state) do
    %{
      send_id: nil,
      macrostep: state.macrostep,
      microstep: state.microstep,
      round: state.round,
      c_index: nil,
      owner: nil
    }
  end

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
