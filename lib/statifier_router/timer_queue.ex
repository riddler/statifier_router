defmodule StatifierRouter.TimerQueue do
  @moduledoc """
  The behaviour a host implements for the durable timer queue a delayed
  route send is recorded on (ADR-0005, decision 5).

  On the process-less shape no session holds anything across a resume -
  those holds are the live session's own state and are not part of
  `Statifier.Position`, and this package resumes on every delivery - so
  the handler owns a delayed send and its `<cancel>` itself, and it owns
  them by writing rows rather than by scheduling anything in memory. The
  queue is the **host's**: this package states the shape and calls it,
  and a host that registers no queue cannot serve a delayed send on a
  route at all, which `StatifierRouter.SendHandler` answers as a refusal
  rather than a silent drop.

  ## The two keys are two keys

  `c:schedule/2` is handed an entry whose **cancellation key** is
  `{scope, send_id}` and whose **dedup key** is the composed
  `t:StatifierRouter.Route.idempotency_key/0` riding beside it. They are
  not one key, and the queue is keyed on the first.

  A send id is not a key on its own. A generated one is minted off a
  per-execution counter and an author-written one is reused verbatim, so
  `send_1` recurs in every execution on the host. A queue keyed on
  `send_id` alone deletes other executions' timers on the first cancel it
  serves.

  ## What a cancel does

  `c:cancel/3` deletes **that scope's** rows for its `send_id`, and no
  other scope's. It may legitimately match more than one row, because
  spec 6.3 cancels every delayed send under an id, and a cancel matching
  nothing is a no-op rather than an error. A cancel carries nothing that
  identifies the route - `%Statifier.Effect.Cancel{}` has no `event`,
  `target` or `type` - which is why `t:entry/0` carries the route name it
  was scheduled against.

  A cancel for a send already fired is a no-op, and a fire for a send
  already cancelled must not happen: the row is the single decision
  point, and both operations are writes against it.
  """

  @typedoc """
  One delayed route send, as it is handed to `c:schedule/2`.

  `scope` and `send_id` are the cancellation key; `key` is the dedup key;
  `route` is the route name the send was scheduled against, and `config`
  that route's resolved configuration; `event` is the built event to
  deliver when it fires; `delay_ms` is the effect's own delay.
  """
  @type entry :: %{
          scope: String.t(),
          send_id: String.t() | nil,
          route: String.t(),
          config: map(),
          event: Statifier.Event.t(),
          key: StatifierRouter.Route.idempotency_key(),
          delay_ms: non_neg_integer()
        }

  @typedoc "A registered timer queue: the module serving it and that module's own configuration."
  @type t :: {module(), map()}

  @doc """
  Records one delayed route send durably, keyed by `{scope, send_id}`.
  """
  @callback schedule(queue_config :: map(), entry :: entry()) :: :ok | {:error, term()}

  @doc """
  Deletes `scope`'s rows for `send_id`, and no other scope's, answering
  how many rows it deleted. Deleting none is a no-op.
  """
  @callback cancel(queue_config :: map(), scope :: String.t(), send_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Whether `module` can serve as a timer queue: loadable and exporting
  `schedule/2` and `cancel/3`.

      iex> StatifierRouter.TimerQueue.valid?(StatifierRouter.TimerQueue)
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(module) when is_atom(module) and not is_nil(module) and not is_boolean(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :schedule, 2) and
      function_exported?(module, :cancel, 3)
  end

  def valid?(_other), do: false
end
