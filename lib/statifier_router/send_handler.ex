defmodule StatifierRouter.SendHandler do
  @moduledoc """
  The one module that serves both shapes a registered type's `<send>`
  reaches a host in (ADR-0005, decision 5). It implements
  `Statifier.Send.Processor` for a live `Statifier.Session`, and it offers
  `handle_effect/3` for a process-less host to call from
  `StatifierPersistence.Executor.execute/2`. Both entry points compose the
  same key, resolve the same route name, and reach the same adapter, so
  there is no second implementation to keep in step.

  A send is this handler's when its `type` is the configuration's
  `:send_type`; an effect of any other type is ignored, because the host's
  executor sees every effect the lifecycle does not consume itself. The
  route name is the send's `target`, which the engine never parses.

  ## The plan/perform split, on the send-processor shape

  `c:Statifier.Send.Processor.deliver/3` and
  `c:Statifier.Send.Processor.cancel/2` are pure planning callbacks,
  called with no process, no clock and no I/O. They compose the key and
  return one `{:handler, __MODULE__, payload}` instruction;
  `c:Statifier.Send.Processor.perform/2` is the impure half and calls the
  adapter. `perform/2` MAY be called more than once for the same send, so
  a route owes at-most-once on the key rather than this module owing
  exactly-once.

  A miss on that shape comes back as `perform/2`'s `{:error, reason}`.
  Reporting it through `Statifier.Session.failed_send/3` is the **host's**,
  which is what that function's own documentation requires: it is called
  by the host, never by `deliver/3` or `cancel/2`.

  ## Where the configuration comes from on each shape

  `handle_effect/3` is handed the configuration, because the host builds
  the executor that calls it:

      executor: fn effect, context ->
        StatifierRouter.SendHandler.handle_effect(config, effect, context)
      end

  The `Statifier.Send.Processor` callbacks are handed no configuration -
  the session registers a bare module and the plan context carries only
  `session_id` - so on that shape the host installs the configuration in
  the process that performs the instructions, with `put_config/1`. That is
  the process the host's own session and executor run in; this package
  does not start sessions.

  ## The idempotency key, and the cancellation key

  The key handed to a route is `t:StatifierRouter.Route.idempotency_key/0`
  (ADR-0005, decision 4): the scope half, where in the step the send sat,
  and the ordinal. The scope half is `execution_id` from the seam context
  at the executor seam and `session_id` from the plan context on the
  send-processor shape.

  The durable timer queue is keyed on something else and smaller -
  `{scope, send_id}`, st-ADR-0054's cancellation key - and the composed
  key rides beside the row as the dedup key. `StatifierRouter.TimerQueue`
  says why the two are two keys.

  ## Delayed sends

  On the process-less shape a `%Statifier.Effect.SendDelayed{}` is
  recorded on the configuration's `:timer_queue`, and a
  `%Statifier.Effect.Cancel{}` deletes that scope's rows for its send id.
  Nothing is scheduled in memory: this package resumes on every delivery,
  and a live session's holds are not part of `Statifier.Position`.

  On the send-processor shape this handler writes no queue row, which is
  what ADR-0005 decision 5 says: only the process-less shape writes the
  durable queue. It also holds no timer, because it is not a process. A
  delayed send on that shape is therefore refused by `perform/2` rather
  than dropped, and the refusal reaches the chart through the host's
  `Statifier.Session.failed_send/3` like any other miss. ADR-0005 decision
  5 and `Statifier.Send.Processor`'s moduledoc do not agree about who
  holds that timer - the record leaves it with the live session, the
  behaviour says the session schedules nothing and the processor owns the
  delay - and resolving that disagreement is a record's work, not this
  module's.

  ## What a route may not do from the executor seam

  A route called at the executor seam runs inside the delivery's
  transaction, under the execution's lock, so it must only hand off
  durably and must never re-enter the sending execution (ADR-0005,
  decision 5). `sending_execution/0` names the execution a route is
  running under, and `StatifierRouter.Delivery.deliver/4` refuses for as
  long as it is set: a route that calls `StatifierRouter.route/3` is
  answered `{:error, {:reentrant_route, execution_id}}` and nothing is
  stepped. That refusal reaches this package's own door only. A route that
  calls `StatifierPersistence.Executions.step/5` directly reaches past it,
  and no reentrancy guard exists there; the record forbids that call, and
  this package cannot enforce it.

  ## The execution target

  One `target` name is reserved, `execution_target/0`'s (ADR-0006, section
  1). A send that writes it is not handed to a route at all: it names
  another durable execution by the `document` and `key` params the chart
  wrote, under the sending execution's own scope, and is delivered through
  `StatifierRouter.Delivery.deliver_event/4` - the same transaction, the
  same get-or-create, the same dedupe row and the same ledger row an
  inbound delivery uses.

      <send type="myapp:router" target="execution" event="pair.joined">
        <param name="document" expr="'placement_counter'"/>
        <param name="key" expr="placement"/>
      </send>

  The scope is never a param: it is read from the sending execution's own
  address row (`StatifierRouter.Addresses.by_execution/2`), so a chart can
  address only inside the scope it runs in. An execution with no address
  row - what `:always_new` produces - has no scope, and its send is
  refused as `unaddressed_sender`, the one refusal with no ledger row,
  because the ledger's `scope` is `NOT NULL` (ADR-0006, section 6).

  The branch is in `handle_effect/3`, beside `mine?/2` and before
  `hand_off/3`, and that placement is load-bearing rather than tidy.
  `hand_off/3` marks a route as running for the length of the dispatch,
  and `StatifierRouter.Delivery.deliver/4` refuses while that mark is set
  (ADR-0005, decision 5). That refusal protects the sending execution's
  own position; ADR-0006 needs a step on a **different** execution inside
  the sender's transaction, which decision 5 never forbade, and section 6
  refuses the one case it would collide with - a send to the sender's own
  address - for that very lock reason. Branching before `hand_off/3` keeps
  the two mechanisms apart rather than narrowing the guard.

  A refusal and a miss are reported to the sender the way ADR-0005,
  section 7 reports an unregistered route: `{:error, reason}` from this
  handler, which at the executor seam re-enters the sending execution as
  `error.communication` carrying the send's `sendid` and does not roll its
  step back. `{:send_refused, reason}` carries one of section 6's five
  reasons and `{:send_undelivered, why}` a `dropped: no_execution` or a
  `dropped: finished`. Four of the five refusals also write one
  `send_refused` ledger row, whose `reason` column holds the record's own
  word for it: `document`, `key`, `create` or `self_address`. The row
  records that the sender was told; it does not stand in for telling it.

  ## The unregistered route

  When the send's `target` names no registered route the lookup misses,
  and the handler answers `{:error, {:unregistered_route, name}}`. At the
  executor seam that return does not roll the step back, deliberately: the
  executor failure is deferred, re-entered as `error.communication`
  carrying the send's `sendid`, and the execution is written anyway. The
  chart hears that its send did not go; the step it just took stands.

  ADR-0005 section 7 also has the handler record that refusal on the
  routing ledger, and it writes one. What the row's columns hold was
  ruled rather than minted here, and the ruling extends ADR-0006,
  section 6's send convention rather than opening a second one:
  `binding_id` is the reserved name `execution`, which is what tells an
  outbound send's row from an inbound delivery's; `message_id` is
  ADR-0005, section 4's composed key, written out as every other row on
  this path writes it; `outcome` is `send_refused`; and `reason` is one
  added word, `route`, naming the target that resolved to no registered
  route. `key` and `execution_id` stay empty, as they do for every
  refusal discovered before a target is resolved. `scope` is the host's
  partition, read from the sending execution's own address row as
  ADR-0006, section 1 reads it, so a sender with no address row is
  reported and not recorded, the same gap section 6 names for
  `unaddressed_sender` and for the same reason: the ledger's `scope` is
  `NOT NULL`.

  The lookup is on the scope half of the composed key, whatever the shape
  put there, and on nothing else: `StatifierRouter.Addresses.by_execution/2`
  is asked for that value's address row. Which shape a refusal came in on
  is not what decides whether a row is written - a scope half that names
  an address row is recorded, one that names none is reported only. On
  the send-processor shape the scope half is the sender's session id, and
  whether that finds a row is the host's arrangement rather than this
  package's guarantee: ADR-0006, section 4 holds that at this package's
  seam the sender's session id is its execution id, so a host that keeps
  them the same is recorded on that shape too.

  The row records that the sender was told and does not stand in for
  telling it: the return is `{:error, {:unregistered_route, name}}` on
  both shapes, unchanged, and the sending step still commits.

  The write is bracketed in a SQL savepoint of its own, for the reason
  `StatifierRouter.Delivery.deliver_event/4` documents at length: this
  handler runs at the executor seam inside the sending execution's own
  transaction, and a failed insert there leaves that transaction aborted,
  which would take the sender's step down with it. An insert that fails
  rolls back to that savepoint and nothing else, and the miss is reported
  either way.

  The bracket is not an absolute, and the code does not pretend it is.
  Only the insert sits inside the guard, so a release that raises after a
  successful insert cannot turn into a rollback of the row it just wrote;
  that release's own failure is swallowed. What is left uncovered is the
  savepoint statements themselves: a connection that has gone away raises
  out of `SAVEPOINT` or out of the rollback, and that raise stands and
  reaches the sender, because a bracket cannot settle a transaction it
  can no longer speak to. What the bracket buys is that a ledger row this
  package could not write is not itself the thing that takes the sender
  down.
  """

  @behaviour Statifier.Send.Processor

  alias Statifier.Effect.Cancel
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierRouter.Addresses
  alias StatifierRouter.Config
  alias StatifierRouter.Delivery
  alias StatifierRouter.Route
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Ledger

  @config_key {__MODULE__, :config}
  @scope_key {__MODULE__, :delivery_scope}
  @in_route_key {__MODULE__, :in_route}

  @execution_target "execution"
  @envelope_params ["document", "key", "create"]

  # RF062-R1: the one reason word added under `send_refused` for a target
  # that names no registered route (ADR-0005, section 7), in the shape
  # ADR-0006, section 6's four reasons already have.
  @unregistered_route_reason "route"

  # ADR-0006, section 2: no binding supplies a horizon here, so the claim
  # takes ADR-0001, section 1's default, the same one
  # `StatifierRouter.Binding`'s struct carries.
  @dedupe %{by: :message_id, horizon_ms: 259_200_000}

  @typedoc "Why this handler did not hand a send off."
  @type reason ::
          {:unregistered_route, String.t() | nil}
          | {:no_timer_queue, String.t() | nil}
          | {:delayed_send_unsupported, String.t() | nil}
          | {:no_config, module()}
          | {:send_refused, refusal()}
          | {:send_undelivered, :no_execution | :finished}
          | term()

  @typedoc """
  Why an execution-to-execution send was refused (ADR-0006, section 6).
  `unaddressed_sender` is the one of the five that writes no ledger row.
  """
  @type refusal :: :unaddressed_sender | :document | :key | :create | :self_address

  @doc """
  The one `target` name ADR-0006, section 1 reserves for the execution
  target. A host may register no route under it and give no binding this
  `id`; `StatifierRouter.Config.new/1` refuses both.

      iex> StatifierRouter.SendHandler.execution_target()
      "execution"
  """
  @spec execution_target() :: String.t()
  def execution_target, do: @execution_target

  # -------------------------------------------------------------------
  # The process-less shape
  # -------------------------------------------------------------------

  @doc """
  Handles one effect at `StatifierPersistence.Executor.execute/2`, with
  that seam's context. An effect whose type is not the configuration's
  `:send_type`, and every effect that is not a send, a delayed send or a
  cancel, is ignored.
  """
  @spec handle_effect(Config.t(), Statifier.Effect.t(), StatifierPersistence.Executor.context()) ::
          :ok | {:error, reason()}
  def handle_effect(config, effect, context)

  def handle_effect(%Config{} = config, {:send, %Send{} = send}, %{execution_id: scope}) do
    cond do
      not mine?(config, send) -> :ok
      send.target == @execution_target -> to_execution(config, send, scope)
      true -> hand_off(config, send, scope)
    end
  end

  def handle_effect(
        %Config{} = config,
        {:send_delayed, %SendDelayed{} = send},
        %{execution_id: scope}
      ) do
    if mine?(config, send), do: enqueue(config, send, scope), else: :ok
  end

  def handle_effect(%Config{} = config, {:cancel, %Cancel{} = cancel}, %{execution_id: scope}),
    do: dequeue(config, cancel, scope)

  def handle_effect(%Config{}, _effect, _context), do: :ok

  # -------------------------------------------------------------------
  # The send-processor shape
  # -------------------------------------------------------------------

  @impl Statifier.Send.Processor
  def deliver(effect, event, ctx)

  def deliver(%Send{} = effect, event, %{session_id: scope}),
    do: {:ok, [{:handler, __MODULE__, {:send, effect, event, key(effect, scope)}}]}

  def deliver(%SendDelayed{} = effect, event, %{session_id: scope}),
    do: {:ok, [{:handler, __MODULE__, {:send_delayed, effect, event, key(effect, scope)}}]}

  @impl Statifier.Send.Processor
  def cancel(%Cancel{} = cancel, %{session_id: scope}),
    do: {:ok, [{:handler, __MODULE__, {:cancel, cancel, scope}}]}

  @impl Statifier.Send.Processor
  def perform(payload, ctx)

  def perform({:send, %Send{} = effect, event, key}, _ctx) do
    case fetch_config() do
      {:ok, config} -> route(config, effect.target, event, key)
      {:error, _reason} = error -> error
    end
  end

  # ADR-0005 decision 5 gives the durable queue to the process-less shape
  # only, and this handler is not a process, so there is nothing here to
  # hold a delay with. Refused rather than dropped: the engine's guarantee
  # is that a failed send is never lost silently.
  def perform({:send_delayed, %SendDelayed{} = effect, _event, _key}, _ctx),
    do: {:error, {:delayed_send_unsupported, effect.send_id}}

  def perform({:cancel, %Cancel{}, _scope}, _ctx), do: :ok

  @impl Statifier.Send.Processor
  def ioprocessors_entry(type) when is_binary(type), do: %{"location" => type}

  # -------------------------------------------------------------------
  # The ambient state: one key per thing, all in the calling process
  # -------------------------------------------------------------------

  @doc """
  Installs the configuration the `Statifier.Send.Processor` callbacks
  serve, in the calling process. `handle_effect/3` is handed its own and
  needs none.
  """
  @spec put_config(Config.t()) :: :ok
  def put_config(%Config{} = config) do
    Process.put(@config_key, config)
    :ok
  end

  @doc "Removes what `put_config/1` installed in the calling process."
  @spec delete_config() :: :ok
  def delete_config do
    Process.delete(@config_key)
    :ok
  end

  @doc """
  The configuration `put_config/1` installed, or
  `{:error, {:no_config, __MODULE__}}` when the host installed none.
  """
  @spec fetch_config() :: {:ok, Config.t()} | {:error, reason()}
  def fetch_config do
    case Process.get(@config_key) do
      %Config{} = config -> {:ok, config}
      nil -> {:error, {:no_config, __MODULE__}}
    end
  end

  @doc """
  The execution a route is running under in the calling process, or `nil`.
  `StatifierRouter.Delivery.deliver/4` refuses for as long as it is set: a
  route called at the executor seam may not re-enter the sending execution
  (ADR-0005, decision 5).
  """
  @spec sending_execution() :: String.t() | nil
  def sending_execution, do: Process.get(@in_route_key)

  # The scope one delivery runs under, which the executor seam's context
  # does not carry and a per-scope override needs.
  # `StatifierRouter.Delivery` sets it for the length of its transaction,
  # which is the process the seam is called in.
  @doc false
  @spec put_delivery_scope(String.t()) :: :ok
  def put_delivery_scope(scope) when is_binary(scope) do
    Process.put(@scope_key, scope)
    :ok
  end

  @doc false
  @spec delete_delivery_scope() :: :ok
  def delete_delivery_scope do
    Process.delete(@scope_key)
    :ok
  end

  # -------------------------------------------------------------------

  @spec mine?(Config.t(), Send.t() | SendDelayed.t()) :: boolean()
  defp mine?(%Config{send_type: send_type}, effect),
    do: is_binary(send_type) and effect.type == send_type

  @spec hand_off(Config.t(), Send.t(), String.t()) :: :ok | {:error, reason()}
  defp hand_off(config, send, scope) do
    in_route(scope, fn ->
      route(config, send.target, SendEvent.build(send, scope), key(send, scope))
    end)
  end

  @spec route(Config.t(), String.t() | nil, Statifier.Event.t(), Route.idempotency_key()) ::
          :ok | {:error, reason()}
  defp route(config, name, event, key) do
    case Config.route(config, override_scope(), name) do
      {:ok, {module, route_config}} -> module.deliver(route_config, event, key)
      :error -> refusal(config, name, key)
    end
  end

  # -------------------------------------------------------------------
  # The execution target (ADR-0006). Reached from handle_effect/3 before
  # hand_off/3, so nothing here runs with a route marked as running.
  # -------------------------------------------------------------------

  @spec to_execution(Config.t(), Send.t(), String.t()) :: :ok | {:error, reason()}
  defp to_execution(config, send, sender) do
    # The sender's scope is read from its own address row, never written by
    # the author (ADR-0006, section 1). A sender with no row has no scope,
    # and the ledger cannot record a refusal without one (section 6).
    case Addresses.by_execution(config, sender) do
      %Address{} = row -> addressed(config, send, sender, row, DateTime.utc_now())
      nil -> {:error, {:send_refused, :unaddressed_sender}}
    end
  end

  @spec addressed(Config.t(), Send.t(), String.t(), Address.t(), DateTime.t()) ::
          :ok | {:error, reason()}
  defp addressed(config, send, sender, %Address{scope: scope} = row, now) do
    case envelope(send, row, sender) do
      {:ok, document, key, create} ->
        deliver_to(config, send, sender, {scope, document, key, create}, now)

      {:refused, why, row_key, execution_id} ->
        refused(config, send, sender, {scope, row_key, execution_id}, why, now)
    end
  end

  @spec deliver_to(
          Config.t(),
          Send.t(),
          String.t(),
          {String.t(), String.t(), String.t(), :if_absent | :never},
          DateTime.t()
        ) :: :ok | {:error, reason()}
  defp deliver_to(config, send, sender, {scope, document, key, create}, now) do
    plan = %{id: @execution_target, document: document, create: create, dedupe: @dedupe}

    delivery = %{
      event: delivered_event(config, send, sender),
      message_id: message_id(key(send, sender)),
      scope: scope,
      now: now
    }

    config
    |> Delivery.deliver_event(plan, key, delivery)
    |> reported()
  end

  # The five outcomes ADR-0006, section 6 reuses from ADR-0004 and what
  # each tells the sender: a delivery, a create and a duplicate landed;
  # the two drops did not reach an execution and are reported as well as
  # recorded (ADR-0006, section 3).
  @spec reported(StatifierRouter.outcome() | {:error, term()}) :: :ok | {:error, reason()}
  defp reported({:created_and_delivered, _name, _execution_id}), do: :ok
  defp reported({:delivered, _name, _execution_id}), do: :ok
  defp reported({:duplicate, _name}), do: :ok
  defp reported({:dropped, _name, why}), do: {:error, {:send_undelivered, why}}
  defp reported({:error, _reason} = error), do: error

  # ADR-0006, section 4. The builder takes no data option and copies the
  # effect's `data` verbatim, so the three envelope params are dropped from
  # the effect handed to it rather than from the event it returns. The
  # sender's execution id plays the session id, so the builder's default
  # `origin` names the sender; `origintype` is the type string the host
  # registered this handler under, which is what a receiver answering "via
  # the Event I/O Processor specified in 'origintype'" reaches.
  @spec delivered_event(Config.t(), Send.t(), String.t()) :: Statifier.Event.t()
  defp delivered_event(%Config{send_type: send_type}, send, sender) do
    SendEvent.build(%{send | data: Map.drop(params(send), @envelope_params)}, sender,
      origintype: send_type
    )
  end

  # `document` and `key` are required and each must resolve to a non-empty
  # string; `create` defaults to `if_absent` and offers two of the three
  # modes (ADR-0006, sections 1 and 3). A send to the sender's own address
  # is refused (section 6): one address row per execution is the create
  # path's invariant (section 1), so the sender's own row carries the only
  # `(document, key)` that names it.
  @spec envelope(Send.t(), Address.t(), String.t()) ::
          {:ok, String.t(), String.t(), :if_absent | :never}
          | {:refused, refusal(), String.t() | nil, String.t() | nil}
  defp envelope(send, %Address{} = row, sender) do
    data = params(send)

    with {:ok, document} <- non_empty(data, "document", :document),
         {:ok, key} <- non_empty(data, "key", :key),
         {:ok, create} <- create_mode(data, key) do
      if row.document == document and row.key == key,
        do: {:refused, :self_address, key, sender},
        else: {:ok, document, key, create}
    end
  end

  @spec params(Send.t()) :: map()
  defp params(%Send{data: data}) when is_map(data), do: data
  defp params(%Send{}), do: %{}

  defp non_empty(data, name, tag) do
    case Map.get(data, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent_or_malformed -> {:refused, tag, nil, nil}
    end
  end

  defp create_mode(data, key) do
    case Map.get(data, "create", "if_absent") do
      "if_absent" -> {:ok, :if_absent}
      "never" -> {:ok, :never}
      _neither_mode -> {:refused, :create, key, nil}
    end
  end

  # ADR-0006, section 6's four recordable reasons. The row is written
  # inside the sending step's own transaction and the step still commits,
  # because the refusal is reported rather than raised. What each reason
  # leaves empty is the record's table: `key` is set from `create` on, and
  # `execution_id` only for `self_address`, which is the sender's own.
  @spec refused(
          Config.t(),
          Send.t(),
          String.t(),
          {String.t(), String.t() | nil, String.t() | nil},
          refusal(),
          DateTime.t()
        ) :: {:error, reason()}
  defp refused(config, send, sender, {scope, row_key, execution_id}, why, now) do
    row = %Ledger{
      binding_id: @execution_target,
      message_id: message_id(key(send, sender)),
      scope: scope,
      outcome: "send_refused",
      key: row_key,
      execution_id: execution_id,
      reason: Atom.to_string(why),
      inserted_at: now
    }

    config.repo.insert!(Config.put_meta(config, row))
    {:error, {:send_refused, why}}
  end

  # The ledger's `message_id` is a string column and ADR-0005, section 4's
  # key is a term, so the key is written out here: the scope half, then
  # each component of the effect half in the order that record lists it,
  # then the ordinal. Every component is a counter or a static content
  # position stamped when the send was executed, so a replayed step writes
  # a byte-identical id and its delivery is a duplicate (ADR-0006, section
  # 2). Nothing parses it back.
  @spec message_id(Route.idempotency_key()) :: String.t()
  defp message_id({scope, position, ordinal}) do
    Enum.map_join(
      [
        scope,
        position.send_id,
        position.macrostep,
        position.microstep,
        position.round,
        position.c_index,
        position.owner,
        ordinal
      ],
      "/",
      &to_id_part/1
    )
  end

  defp to_id_part(value) when is_binary(value), do: value
  defp to_id_part(value) when is_integer(value), do: Integer.to_string(value)
  defp to_id_part(value), do: inspect(value)

  @spec enqueue(Config.t(), SendDelayed.t(), String.t()) :: :ok | {:error, reason()}
  defp enqueue(config, send, scope) do
    key = key(send, scope)

    case Config.route(config, override_scope(), send.target) do
      {:ok, {_module, route_config}} -> schedule(config, send, scope, route_config, key)
      :error -> refusal(config, send.target, key)
    end
  end

  @spec schedule(Config.t(), SendDelayed.t(), String.t(), map(), Route.idempotency_key()) ::
          :ok | {:error, reason()}
  defp schedule(%Config{timer_queue: nil}, send, _scope, _route_config, _key),
    do: {:error, {:no_timer_queue, send.send_id}}

  defp schedule(%Config{timer_queue: {module, queue_config}}, send, scope, route_config, key) do
    module.schedule(queue_config, %{
      scope: scope,
      send_id: send.send_id,
      route: send.target,
      config: route_config,
      event: SendEvent.build(send, scope),
      key: key,
      delay_ms: send.delay_ms
    })
  end

  # A cancel carries no type, so whether it names a send this handler was
  # given is not knowable here: it is asked of the queue, and a cancel
  # that matches nothing is a no-op rather than an error. A host with no
  # queue has nothing to cancel.
  @spec dequeue(Config.t(), Cancel.t(), String.t()) :: :ok | {:error, reason()}
  defp dequeue(%Config{timer_queue: nil}, _cancel, _scope), do: :ok

  defp dequeue(%Config{timer_queue: {module, queue_config}}, cancel, scope) do
    case module.cancel(queue_config, scope, cancel.send_id) do
      {:ok, _deleted} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # ADR-0005 section 7's run-time miss, both halves: the ledger row that
  # records the refusal and the error the sender hears. Recording is
  # attempted first and never governs the return, because section 7 owes
  # the sender the report whatever the ledger does. The moduledoc's "The
  # unregistered route" section says what each column holds and who ruled
  # it.
  @spec refusal(Config.t(), String.t() | nil, Route.idempotency_key()) :: {:error, reason()}
  defp refusal(config, name, key) do
    record_refusal(config, key, DateTime.utc_now())
    {:error, {:unregistered_route, name}}
  end

  # The ledger's `scope` is the host's partition (ADR-0004, section 4),
  # never an execution id, so it is read from the sender's own address row
  # exactly as ADR-0006, section 1 reads it. A sender with no such row has
  # no scope, and the ledger's `scope` is `NOT NULL`, so its refusal is
  # reported and not recorded - the same gap ADR-0006, section 6 names for
  # `unaddressed_sender`, for the same reason. On the send-processor shape
  # the key's scope half is a session id and no address row answers to it,
  # which is the same case.
  @spec record_refusal(Config.t(), Route.idempotency_key(), DateTime.t()) :: :ok
  defp record_refusal(config, {sender, _position, _ordinal} = key, now) do
    case Addresses.by_execution(config, sender) do
      %Address{scope: scope} -> insert_refusal(config, scope, message_id(key), now)
      nil -> :ok
    end
  end

  @spec insert_refusal(Config.t(), String.t(), String.t(), DateTime.t()) :: :ok
  defp insert_refusal(config, scope, message_id, now) do
    row = %Ledger{
      binding_id: @execution_target,
      message_id: message_id,
      scope: scope,
      outcome: "send_refused",
      key: nil,
      execution_id: nil,
      reason: @unregistered_route_reason,
      inserted_at: now
    }

    # The transaction is what gives the savepoint something to live in
    # when this handler is called outside one, as it is on the
    # send-processor shape - which reaches this insert whenever the key's
    # scope half names an address row; at the executor seam it nests and
    # the savepoint is what settles this insert on its own.
    config.repo.transaction(fn -> insert_guarded(config, row) end)
    :ok
  end

  # A failed ledger write must not take the sender's step down with it,
  # and inside the sender's transaction any failed statement would: the
  # transaction is left aborted whether or not the caller handles the
  # error. So the insert gets its own savepoint and its failure is
  # rolled back to it. Reporting the miss is the obligation ADR-0005
  # section 7 puts first, and it is met either way.
  #
  # ONLY the insert sits inside the `try`, and that is the whole point of
  # the shape. A `RELEASE SAVEPOINT` in there would invert the bracket: a
  # raise from the release fires the `rescue`, which then issues
  # `ROLLBACK TO SAVEPOINT` against a savepoint that may already be gone,
  # and that second raise escapes into the sender's step - the one thing
  # this bracket exists to prevent. So the release runs after the `try`,
  # on the success path only, through `release/2`, which swallows its own
  # failure: the row is written by the time it runs, and a release that
  # cannot run means the connection is already gone, which is the
  # sender's transaction to lose and not this row's to take.
  #
  # The rollback keeps no such guard, deliberately. It runs only where
  # the insert failed, so the savepoint is known to be there, and a raise
  # out of it means the connection is gone - and that raise stands.
  @spec insert_guarded(Config.t(), Ledger.t()) :: :ok | :error
  defp insert_guarded(config, row) do
    savepoint = "sr_route_refusal_#{System.unique_integer([:positive])}"
    config.repo.query!("SAVEPOINT " <> savepoint)

    inserted? =
      try do
        config.repo.insert!(Config.put_meta(config, row))
        true
      rescue
        _insert_failed -> false
      end

    if inserted? do
      release(config, savepoint)
      :ok
    else
      config.repo.query!("ROLLBACK TO SAVEPOINT " <> savepoint)
      :error
    end
  end

  # The release of a savepoint whose insert already landed. Its failure
  # is swallowed rather than reported, for the reason `insert_guarded/2`
  # gives: it cannot lose the row, and it must not be the statement that
  # takes the sender down.
  @spec release(Config.t(), String.t()) :: :ok
  defp release(config, savepoint) do
    config.repo.query!("RELEASE SAVEPOINT " <> savepoint)
    :ok
  rescue
    _release_failed -> :ok
  end

  @spec key(Send.t() | SendDelayed.t(), String.t()) :: Route.idempotency_key()
  defp key(effect, scope) do
    {scope,
     %{
       send_id: effect.send_id,
       macrostep: effect.macrostep,
       microstep: effect.microstep,
       round: effect.round,
       c_index: effect.c_index,
       owner: effect.owner
     }, effect.ordinal}
  end

  @spec override_scope() :: String.t() | nil
  defp override_scope, do: Process.get(@scope_key)

  @spec in_route(String.t(), (-> result)) :: result when result: var
  defp in_route(scope, fun) do
    Process.put(@in_route_key, scope)
    fun.()
  after
    Process.delete(@in_route_key)
  end
end
