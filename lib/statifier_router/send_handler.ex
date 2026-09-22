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

  ## The unregistered route

  When the send's `target` names no registered route the lookup misses,
  and the handler answers `{:error, {:unregistered_route, name}}`. At the
  executor seam that return does not roll the step back, deliberately: the
  executor failure is deferred, re-entered as `error.communication`
  carrying the send's `sendid`, and the execution is written anyway. The
  chart hears that its send did not go; the step it just took stands.

  ADR-0005 section 7 also has the handler record that refusal on the
  routing ledger, and this module does not write that row yet. The
  ledger's `binding_id` and `message_id` are both `NOT NULL`
  (`StatifierRouter.Migrations.V01`) and an outbound route refusal has
  neither a binding nor an inbound message, and ADR-0004 section 4 fixes
  the `outcome` column to that record's inbound vocabulary, which has no
  word for a send refusal. Minting one is record surface. `refusal/2`
  below is where that write goes when the values are ruled; the reported
  miss and the committed step are built and pinned today.
  """

  @behaviour Statifier.Send.Processor

  alias Statifier.Effect.Cancel
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierRouter.Config
  alias StatifierRouter.Route

  @config_key {__MODULE__, :config}
  @scope_key {__MODULE__, :delivery_scope}
  @in_route_key {__MODULE__, :in_route}

  @typedoc "Why this handler did not hand a send off."
  @type reason ::
          {:unregistered_route, String.t() | nil}
          | {:no_timer_queue, String.t() | nil}
          | {:delayed_send_unsupported, String.t() | nil}
          | {:no_config, module()}
          | term()

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
    if mine?(config, send), do: hand_off(config, send, scope), else: :ok
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
      :error -> refusal(name, key)
    end
  end

  @spec enqueue(Config.t(), SendDelayed.t(), String.t()) :: :ok | {:error, reason()}
  defp enqueue(config, send, scope) do
    key = key(send, scope)

    case Config.route(config, override_scope(), send.target) do
      {:ok, {_module, route_config}} -> schedule(config, send, scope, route_config, key)
      :error -> refusal(send.target, key)
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

  # ADR-0005 section 7's run-time miss. The reported miss and the step
  # that still commits are here; the routing-ledger row is not, and the
  # moduledoc's "The unregistered route" section says which column values
  # are unruled and why minting them is not this module's to do. The row
  # is written here when they are ruled.
  @spec refusal(String.t() | nil, Route.idempotency_key()) :: {:error, reason()}
  defp refusal(name, _key), do: {:error, {:unregistered_route, name}}

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
