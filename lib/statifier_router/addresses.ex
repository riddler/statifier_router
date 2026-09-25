defmodule StatifierRouter.Addresses do
  @moduledoc """
  The address table's own two functions: `reap/2`, which removes address
  rows whose execution finished longer ago than their horizon (ADR-0002,
  sections 5 and 6), and `by_execution/2`, which reads the row naming one
  execution.

  ## The two handles it works on

  `reap/2` takes the router's configuration as the storage it works on,
  and the configuration carries both handles it needs:

    * the host's `:repo`, with the `:table_prefix` and `:prefix` that name
      the address table in it (`StatifierRouter.Config.table/2`): the rows
      it reads, stamps and deletes;
    * the `:store`, the `%StatifierPersistence.Storage{}` the executions
      are kept in: the only thing it reads there is an execution's status,
      through `StatifierPersistence.Storage.fetch_execution/2`.

  A configuration without a `:store` is refused by the function head. The
  bindings are the second argument, the host's current ones, and not the
  configuration's: the horizon is computed from the bindings handed to each
  reap.

  ## What one reap does

  For each address row it examines, in the order of the rows' ids:

    * a row already stamped `terminal_seen_at` is not read again: a
      terminal execution stays terminal;
    * for a row not yet stamped, it reads the execution's status. An
      `:active` execution leaves the row as it is. A terminal one
      (`:completed`, `:failed` or `:cancelled`) is seen terminal now, and
      its row is stamped with the reap's time unless the next rule deletes
      it in the same reap;
    * a row whose execution is terminal is deleted once its horizon has
      elapsed since `terminal_seen_at`: when `terminal_seen_at` plus the
      horizon is not later than the reap's time;
    * a row not yet stamped whose execution the store no longer holds -
      `fetch_execution/2` answers `{:error, :execution_not_found}` - is
      deleted at this reap, whatever its horizon. The row's only use is to
      reach that execution, and a late event for its address can no longer
      be resolved to it and recorded as a drop, so nothing is kept by
      keeping the row. A row already stamped is not read again, so an
      execution removed after its row was stamped frees the row by its
      horizon rather than by this rule.

  The horizon of a row is the longest dedupe horizon, `horizon_ms`, of any
  enabled binding among `bindings` whose `document` is the row's document.
  A document no enabled binding names has a horizon of zero. So disabling
  or removing every binding for a document frees the rows of its finished
  executions at the next reap, including a row that reap is the first to
  see terminal; a later event for such an address opens a fresh execution
  under `:if_absent`.

  It deletes address rows only. It never deletes, alters or steps an
  execution, and it never writes the input log.

  ## Its cost is bounded

  Every row not yet stamped costs one status read, so a reap over every
  row would grow with the number of live addresses. One call examines at
  most `:limit` rows (1000 by default), those whose id is greater than
  `:after`, and answers with `next`: the id of the last row it examined
  when it examined a full `:limit` of them, and `nil` when it reached the
  end of the table. A host sweeps the whole table by calling again with
  `after: next` until `next` is `nil`. A host that only ever calls `reap/2`
  with no options examines the first `:limit` rows each time, which frees
  nothing behind them.

  An `{:error, reason}` from `fetch_execution/2` for any examined row ends
  the call before it writes anything, and is returned. The one exception is
  `:execution_not_found`, which the rules above make a deletion rather than
  a refusal: without it one orphaned row would end every sweep that reaches
  it, and the rows behind it would never be examined again.

  This package runs no process to call it: the host schedules it, as it
  schedules `StatifierRouter.Dedupe.reap/2` (ADR-0002, section 6).
  """

  import Ecto.Query, only: [from: 2]

  alias StatifierPersistence.Storage
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address

  @terminal [:completed, :failed, :cancelled]
  @default_limit 1_000

  @typedoc """
  What one reap did: how many rows it stamped `terminal_seen_at` on, how
  many it deleted, and the cursor to continue from, or `nil` at the end of
  the table.
  """
  @type result :: %{
          stamped: non_neg_integer(),
          deleted: non_neg_integer(),
          next: pos_integer() | nil
        }

  @doc """
  The address row naming `execution_id`, or `nil` when no row names it.

  ADR-0002, section 1's unique index is on `(scope, document, key)`, and
  the `execution_id` index `StatifierRouter.Migrations.V01.up/1` adds is
  not unique; what keeps the count at one row per execution is that each
  create mints a fresh id and writes at most one row for it (ADR-0006,
  section 1). This function reads the first row in id order rather than
  asserting that invariant, so a second row cannot turn a read into a
  raise.

  An execution created under `:always_new` has no row at all (ADR-0002,
  section 7), and so has neither a scope nor a key of its own: that is the
  `nil` an execution-to-execution send is refused for as
  `unaddressed_sender` (ADR-0006, section 6).
  """
  @spec by_execution(Config.t(), String.t()) :: Address.t() | nil
  def by_execution(%Config{} = config, execution_id) when is_binary(execution_id) do
    config.repo.one(
      from(a in Config.queryable(config, Address),
        where: a.execution_id == ^execution_id,
        order_by: a.id,
        limit: 1
      )
    )
  end

  @doc """
  Stamps and deletes the address rows under `config` as the module
  documentation describes, with each row's horizon computed from
  `bindings`. A host whose configuration gives a `:bindings_resolver`
  hands it the bindings of every scope it routes, since a row's horizon
  is read by document alone (ADR-0001, the Amendment of 2026-09-25).

  `opts`:

    * `:now` - a `DateTime` in UTC, the reap's time. Defaults to
      `DateTime.utc_now/0`.
    * `:limit` - a positive integer, the most rows this call examines.
      Defaults to 1000.
    * `:after` - `nil` or a positive integer: examine only rows whose id
      is greater. Defaults to `nil`, the start of the table.

  Returns `{:ok, result}`, `{:error, reason}` from
  `StatifierPersistence.Storage.fetch_execution/2` other than
  `:execution_not_found`, which deletes the row instead, or
  `{:error, reason}` for a malformed option (`{:invalid_opts, opts}`,
  `{:unknown_key, name}`, `{:invalid_value, name, value}`).
  """
  @spec reap(Config.t(), [Binding.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def reap(%Config{store: %Storage{}} = config, bindings, opts \\ []) when is_list(bindings) do
    with {:ok, now, limit, after_id} <- options(opts),
         rows = examine(config, after_id, limit),
         {:ok, acted} <- classify_rows(config, rows, now) do
      horizons = horizons(bindings)
      {due, kept} = Enum.split_with(acted, &due?(&1, horizons, now))

      {:ok,
       %{
         stamped: stamp(config, for({row, :new} <- kept, do: row.id), now),
         deleted: delete(config, for({row, _seen} <- due, do: row.id)),
         next: next(rows, limit)
       }}
    end
  end

  defp examine(config, after_id, limit) do
    config.repo.all(
      from(a in Config.queryable(config, Address),
        where: a.id > ^after_id,
        order_by: a.id,
        limit: ^limit
      )
    )
  end

  # Every examined row this reap acts on, as {row, :seen} when it was
  # already stamped terminal, {row, :new} when this reap is the first to
  # see it terminal, and {row, :orphan} when the store no longer holds its
  # execution. Nothing is written until every read has succeeded.
  defp classify_rows(config, rows, now) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case classify(config, row, now) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp classify(_config, %Address{terminal_seen_at: %DateTime{}} = row, _now),
    do: {:ok, {row, :seen}}

  defp classify(config, %Address{} = row, now) do
    case Storage.fetch_execution(config.store, row.execution_id) do
      {:ok, %{status: status}} when status in @terminal ->
        {:ok, {%{row | terminal_seen_at: now}, :new}}

      {:ok, _active} ->
        {:ok, nil}

      {:error, :execution_not_found} ->
        {:ok, {row, :orphan}}

      {:error, _reason} = error ->
        error
    end
  end

  # The longest horizon of any enabled binding naming each document; a
  # document absent from the map has a horizon of zero.
  defp horizons(bindings) do
    for %Binding{enabled: true, document: document, dedupe: %{horizon_ms: ms}} <- bindings,
        reduce: %{} do
      acc -> Map.update(acc, document, ms, &max(&1, ms))
    end
  end

  # An orphan has no terminal_seen_at to count a horizon from, and keeping
  # it serves nothing: it is due at the reap that first reads it.
  defp due?({%Address{}, :orphan}, _horizons, _now), do: true

  defp due?({%Address{document: document, terminal_seen_at: seen_at}, _how}, horizons, now) do
    horizon_ms = Map.get(horizons, document, 0)
    DateTime.compare(DateTime.add(seen_at, horizon_ms, :millisecond), now) != :gt
  end

  defp stamp(_config, [], _now), do: 0

  defp stamp(config, ids, now) do
    {count, _} =
      from(a in Config.queryable(config, Address),
        where: a.id in ^ids and is_nil(a.terminal_seen_at)
      )
      |> config.repo.update_all(set: [terminal_seen_at: now])

    count
  end

  defp delete(_config, []), do: 0

  defp delete(config, ids) do
    {count, _} =
      config.repo.delete_all(from(a in Config.queryable(config, Address), where: a.id in ^ids))

    count
  end

  defp next(rows, limit) when length(rows) == limit, do: List.last(rows).id
  defp next(_rows, _limit), do: nil

  defp options(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_opts, opts}},
         :ok <- Config.reject_unknown(opts, [:now, :limit, :after]),
         {:ok, now} <- now(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)),
         {:ok, limit} <- limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, after_id} <- after_id(Keyword.get(opts, :after)) do
      {:ok, now, limit, after_id}
    end
  end

  defp now(%DateTime{time_zone: "Etc/UTC", microsecond: {usec, _precision}} = now),
    do: {:ok, %{now | microsecond: {usec, 6}}}

  defp now(other), do: {:error, {:invalid_value, :now, other}}

  defp limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp limit(other), do: {:error, {:invalid_value, :limit, other}}

  defp after_id(nil), do: {:ok, 0}
  defp after_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp after_id(other), do: {:error, {:invalid_value, :after, other}}
end
