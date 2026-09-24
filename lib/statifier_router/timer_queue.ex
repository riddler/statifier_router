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

  `c:StatifierRouter.TimerQueue.schedule/2` is handed an entry whose
  **cancellation key** is `{scope, send_id}` and whose **dedup key** is
  the composed `t:StatifierRouter.Route.idempotency_key/0` riding beside
  it. They are not one key, and the queue is keyed on the first.

  A send id is not a key on its own. A generated one is minted off a
  per-execution counter and an author-written one is reused verbatim, so
  `send_1` recurs in every execution on the host. A queue keyed on
  `send_id` alone deletes other executions' timers on the first cancel it
  serves.

  The queue holds **at most one row per dedup key**. Under at-least-once
  delivery the same delayed send can reach
  `c:StatifierRouter.TimerQueue.schedule/2` more than once, with the same
  `key` each time, and a queue that appends a row per call fires that send
  once per call. So a `c:StatifierRouter.TimerQueue.schedule/2` whose
  `key` the queue already holds a row for adds no second row and answers
  `:ok`. Two entries under one `{scope, send_id}` with different keys are
  two sends, and both are kept.

  That rule dedups against the rows the queue still holds, and a fire
  deletes its row (see "Firing a row" below), so the rule alone does not
  make a send fire at most once: a repeat that reaches
  `c:StatifierRouter.TimerQueue.schedule/2` after the row has fired adds
  a row, and that row fires again. The delivery stays at most once end to
  end because the fire hands the route the row's own `key`, and the route
  owes at-most-once on that key (ADR-0005, decision 4): the second firing
  reaches the route under a key it has already served. A queue that also
  remembers the keys it has fired, and adds no row for one of them, stops
  the repeat before the route; this behaviour does not require it.

  ## What a cancel does

  `c:StatifierRouter.TimerQueue.cancel/3` deletes **that scope's** rows for
  its `send_id`, and no other scope's. It may legitimately match more than
  one row, because spec 6.3 cancels every delayed send under an id, and a
  cancel matching nothing is a no-op rather than an error. A cancel
  carries nothing that identifies the route - `%Statifier.Effect.Cancel{}`
  has no `event`, `target` or `type` - which is why `t:entry/0` carries
  the route name it was scheduled against.

  A cancel for a send already fired is a no-op, and a fire for a send
  already cancelled must not happen: the row is the single decision
  point, and both operations are writes against it.

  ## Firing a row

  This behaviour has no fire callback, because firing is the host's: the
  queue is the host's and so is whatever wakes it when `delay_ms` has
  passed. A host fires a row in two steps, without leaving this package's
  public surface.

  **First, the fire-time check.** A delayed send whose owner has ended is
  discarded without being delivered: spec 6.2 requires it, and once the
  queue holds the send nothing but the fire can do it.
  `Statifier.Send.Processor` says so for the send-processor shape - the
  processor owns the delay, "and spec 6.2's discard at termination is its
  fire-time check" - and statifier-ex's ADR-0054, decision 4 says how the
  check is read, and in which order. A row
  `StatifierRouter.SendHandler.perform/2` wrote is scoped by a session id,
  and fires only while that session still exists and is not halted: it is
  found under its id (`Registry.lookup(Statifier.Registry, scope)` for a
  session registered there), and `Statifier.Session.status/1` reports it
  `:running`. A row written at the executor seam is scoped by an
  execution id, and fires only while that execution's stored record
  reads `:active`. A row whose owner fails the check is deleted with no
  delivery, in the write that would have fired it.

  **Then the delivery.**

      {:ok, {module, _registered}} = StatifierRouter.Config.route(config, nil, entry.route)
      :ok = module.deliver(entry.config, entry.event, entry.key)

  `StatifierRouter.Config.route/3` answers the module serving the route
  name the row carries; a scope overrides a route's configuration, never
  its existence (ADR-0005, decision 2), so the module does not depend on
  the scope passed. The configuration handed to
  `c:StatifierRouter.Route.deliver/3` is the row's own `config`, the one
  resolved under the delivery's scope when the send was scheduled, and
  the key is the row's own `key`, on which the route owes at-most-once
  in turn. `:error` from `StatifierRouter.Config.route/3` means the route
  name was unregistered after the row was written.

  A fire, like a cancel, is a write against the row (ADR-0005, decision
  5): the fire deletes the row in the same write that decides it fires,
  so that a cancel and a fire of one row cannot both succeed.
  """

  @typedoc """
  One delayed route send, as it is handed to
  `c:StatifierRouter.TimerQueue.schedule/2`.

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
  Records one delayed route send durably, keyed by `{scope, send_id}`,
  with at most one held row per `entry.key`.

  `entry.key` is the dedup key (ADR-0005, decision 5): when the queue
  already holds a row with that key, this adds no second row and
  answers `:ok`. Entries with different keys under one
  `{scope, send_id}` are separate rows. A row already fired is no longer
  held, so a repeat after the fire is absorbed by the route's
  at-most-once on the key (ADR-0005, decision 4), as the moduledoc says.
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
