defmodule StatifierRouter.SourceInvoke do
  @moduledoc """
  The source invoke's two calls, as a host's invoke handler makes them:
  `start/3` turns a `%Statifier.Effect.Invoke{}` into
  `StatifierRouter.subscribe/3`, and `cancel/3` turns the
  `%Statifier.Effect.CancelInvoke{}` the engine emits on state exit into
  `StatifierRouter.cancel/2` (ADR-0007, section 2). An invocation's
  lifetime is a subscription's, and the chart writes no cleanup for it.

  The chart's half is one element, whose params name the binding and
  nothing else (ADR-0007, section 1):

      <invoke type="myapp:source">
        <param name="binding" expr="'clicks_to_join'"/>
      </invoke>

  The `type` is the host's own string, registered in the
  `t:Statifier.Invoke.Types.t/0` snapshot it stamps; this module never
  reads it, so a host may serve as many source invoke types as it likes
  with one delegate.

  ## Why this is a delegate and not a `@behaviour`

  It does **not** implement `Statifier.Invoke.Handler` (statifier 2.6.0,
  the version `mix.lock` resolves), and it cannot. That behaviour's
  `c:start/2` and `c:cancel/2` are **pure planning callbacks**, called
  from `Statifier.Session.Effects.plan/2`'s own fold with "no process, no
  clock, and no I/O"; they return instructions for an executor to perform.
  Subscribing writes a row, so it belongs in the impure half. The
  callbacks also carry no slot for it: the plan context is
  `%{session_id: _, invoke_types: _, invoke_handlers: _}` and carries "no
  pid, no `%MachineState{}`, and no session struct", so neither a
  `StatifierRouter.Config` nor the execution id can reach a planning
  callback at all.

  So a host that runs a live `Statifier.Session` writes a handler whose
  `c:start/2` returns `{:ok, [{:handler, __MODULE__, payload}]}` and whose
  `c:perform/2` calls `start/3` here. A durable host - the mode ADR-0007,
  section 5 specifies, and the only one - has an executor rather than a
  session: both effects arrive at the executor seam this package already
  hands `StatifierPersistence.Executions.create/4` and `step/5`, where
  the execution id is in the context and the configuration is in hand, and
  that handler calls straight into these two functions.

  ## Idempotency

  Both calls are idempotent, which is the contract either door needs.
  `Statifier.Invoke.Handler` says a `c:perform/2` "MUST be idempotent on
  `invoke_id`", because a host that crashes between performing an
  instruction and recording that it ran replays the same drive; and it
  says a cancel "MAY be planned for an invocation a host has already
  reported complete", so a handler "MUST tolerate cancelling an
  `invoke_id` it no longer knows". `start/3` answers
  `{:ok, :already_subscribed}` for the second call and `cancel/3`
  `{:ok, :not_subscribed}`; neither is an error.

  ## What it refuses

  An execution created under `:always_new` has no address row, so it has
  no key to subscribe under and its source invoke is refused rather than
  subscribed under an invented key (ADR-0007, section 6). That reaches a
  caller as `{:error, {:unaddressed_execution, execution_id}}` from
  `StatifierRouter.subscribe/3`. An invoke whose params do not carry a
  `binding` is refused here, before any read.
  """

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Invoke
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Subscription

  @binding_param "binding"

  @typedoc "Why a source invoke was refused rather than subscribed."
  @type refusal ::
          {:missing_binding_param, term()}
          | {:unknown_binding, String.t()}
          | {:unaddressed_execution, String.t()}

  @doc """
  Subscribes `execution_id` to the binding named by `invoke`'s `binding`
  param, under `invoke`'s own `invoke_id`.

  Returns what `StatifierRouter.subscribe/3` returns, or
  `{:error, {:missing_binding_param, params}}` when the invoke carries no
  `binding` param of its own. `Statifier.Effect.Invoke`'s `params` is the
  resolved `<param>`/namelist payload as a string-keyed map, or
  `:undefined` when the element has none (statifier 2.6.0).
  """
  @spec start(Config.t(), String.t(), Invoke.t()) ::
          {:ok, :subscribed | :already_subscribed} | {:error, refusal()}
  def start(%Config{} = config, execution_id, %Invoke{} = invoke)
      when is_binary(execution_id) do
    case binding_id(invoke.params) do
      {:ok, binding_id} ->
        StatifierRouter.subscribe(config, binding_id, {execution_id, invoke.invoke_id})

      :error ->
        {:error, {:missing_binding_param, invoke.params}}
    end
  end

  @doc """
  Cancels the subscription the matching `start/3` created, naming it by
  `execution_id` and the cancellation's `invoke_id`.

  The engine's `%Statifier.Effect.CancelInvoke{}` carries an `invoke_id`
  and the exiting state's index and no binding - deliberately, since
  widening that callback was refused upstream - so this reads the binding
  back off the subscription row before calling
  `StatifierRouter.cancel/2`. A cancellation for an invocation with no row
  is `{:ok, :not_subscribed}`.
  """
  @spec cancel(Config.t(), String.t(), CancelInvoke.t()) :: {:ok, :cancelled | :not_subscribed}
  def cancel(%Config{} = config, execution_id, %CancelInvoke{invoke_id: invoke_id})
      when is_binary(execution_id) do
    case subscribed_binding(config, execution_id, invoke_id) do
      nil -> {:ok, :not_subscribed}
      binding_id -> StatifierRouter.cancel(config, {binding_id, execution_id, invoke_id})
    end
  end

  defp binding_id(%{@binding_param => binding_id})
       when is_binary(binding_id) and binding_id != "",
       do: {:ok, binding_id}

  defp binding_id(_params), do: :error

  defp subscribed_binding(config, execution_id, invoke_id) do
    config.repo.one(
      from(s in Config.queryable(config, Subscription),
        where: s.execution_id == ^execution_id and s.invoke_id == ^invoke_id,
        order_by: s.id,
        limit: 1,
        select: s.binding_id
      )
    )
  end
end
