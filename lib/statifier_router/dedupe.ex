defmodule StatifierRouter.Dedupe do
  @moduledoc """
  Dedupe on `(binding_id, message_id)`, with a row expiry (ADR-0003,
  section 6).

  `claim/4` is the first write of every delivery transaction
  `StatifierRouter.Delivery` opens (ADR-0003, section 1). It answers
  `:new` when this delivery is the first of its pair within the binding's
  horizon, and `:duplicate` when a row for the pair is present and
  unexpired; on `:duplicate` the delivery writes its ledger row and nothing
  else. The row commits or rolls back with the delivery, so a delivery
  that rolls back leaves no row and its redelivery is attempted again.

  A row carries `expires_at`, the delivery's time plus the binding's
  `dedupe` horizon, `horizon_ms`. A row whose `expires_at` is earlier than
  the delivery's time counts as absent, even before `reap/2` removes it.

  ## How an expired row counts as absent

  `claim/4` is one statement: an insert that, on a conflict with the
  unique index on `(binding_id, message_id)`, updates the stored row's
  `expires_at` only when the stored row has expired (on Postgres,
  `INSERT ... ON CONFLICT (binding_id, message_id) DO UPDATE SET
  expires_at = ... WHERE <stored>.expires_at < now`). The statement
  affects one row when it inserted a row or replaced an expired one, and
  none when the stored row is unexpired, and that count is the answer.

  It is one statement rather than a delete of the expired row followed by
  an insert for two reasons. The replacement of an expired row goes
  through the same row lock and the same unique-index wait that settle
  two concurrent claims of one pair (ADR-0003, sections 3 and 6): a
  second claim waits for the first transaction, then, if the first
  committed, finds the row unexpired and is a duplicate, and if it rolled
  back, proceeds. And the answer is the one row count of the one write,
  with no read of the row to decide it.

  ## Reaping

  `reap/2` deletes the rows whose `expires_at` is earlier than the time it
  is handed, and nothing else. It is a plain function: this package starts
  no process to call it, and the host schedules it (ADR-0003, section 9).
  A host that never calls it keeps every row, which is correct and only
  costs space, since an expired row already counts as absent.

  The message id is taken as given. Deriving it is the source adapter's
  job, which this package does not ship (ADR-0003, section 6).
  """

  import Ecto.Query, only: [from: 2]

  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Dedupe, as: Row

  @doc """
  Claims `message_id` for `claimant` at `now`, inside the caller's
  transaction on the configuration's repo.

  The claimant is whatever the pair's rows are counted under: a
  `t:StatifierRouter.Binding.t/0` for an inbound delivery, and
  `t:StatifierRouter.Delivery.plan/0` for an execution-to-execution send,
  whose name is ADR-0006's reserved one and whose horizon is ADR-0001,
  section 1's default. Only the `id` and the `horizon_ms` are read.

  Returns `:new` when it wrote the pair's row, a new one or one replacing
  an expired row, with `expires_at` set to `now` plus the claimant's
  `horizon_ms`; returns `:duplicate` when the pair's row is present and
  its `expires_at` is not earlier than `now`, and writes nothing.
  """
  @spec claim(
          Config.t(),
          Binding.t() | StatifierRouter.Delivery.plan(),
          String.t(),
          DateTime.t()
        ) :: :new | :duplicate
  def claim(
        %Config{} = config,
        %{id: binding_id, dedupe: %{horizon_ms: horizon_ms}},
        message_id,
        %DateTime{} = now
      )
      when is_binary(message_id) and message_id != "" do
    expires_at = DateTime.add(now, horizon_ms, :millisecond)

    replace_expired =
      from(d in Config.queryable(config, Row),
        where: d.expires_at < ^now,
        update: [set: [expires_at: ^expires_at]]
      )

    row = %{binding_id: binding_id, message_id: message_id, expires_at: expires_at}

    case config.repo.insert_all({Config.table(config, :dedupe), Row}, [row],
           prefix: config.prefix,
           on_conflict: replace_expired,
           conflict_target: [:binding_id, :message_id]
         ) do
      {1, _} -> :new
      {0, _} -> :duplicate
    end
  end

  @doc """
  Deletes every dedupe row under the configuration whose `expires_at` is
  earlier than `now`, and returns `{:ok, count}` with the number deleted.
  """
  @spec reap(Config.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def reap(%Config{} = config, %DateTime{} = now) do
    {count, _} =
      config.repo.delete_all(from(d in Config.queryable(config, Row), where: d.expires_at < ^now))

    {:ok, count}
  end
end
