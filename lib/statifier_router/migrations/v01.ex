defmodule StatifierRouter.Migrations.V01 do
  @moduledoc """
  V01 of the package DDL: the three tables the decision records fix, each
  named by `StatifierRouter.Config.table/2` under the host's table prefix
  and created in the host's Postgres schema when one is set.

  **`addresses`** (ADR-0002, section 1): `(scope, document, key)` ->
  `execution_id`.

  | Column | Type | Null |
  |---|---|---|
  | `id` | `bigserial`, primary key | no |
  | `scope` | `text` | no |
  | `document` | `text` | no |
  | `key` | `text` | no |
  | `execution_id` | `text` | no |
  | `inserted_at` | `utc_datetime_usec` | no |
  | `terminal_seen_at` | `utc_datetime_usec` | yes, empty until the execution is first seen terminal |

  Indexes: the unique `<table>_scope_document_key_index` on
  `(scope, document, key)`, and `<table>_execution_id_index` on
  `execution_id`, so the rows naming one execution are found without a
  scan.

  **`dedupe`** (ADR-0003, section 6): one row per `(binding_id,
  message_id)` a delivery got past the dedupe step with.

  | Column | Type | Null |
  |---|---|---|
  | `id` | `bigserial`, primary key | no |
  | `binding_id` | `text` | no |
  | `message_id` | `text` | no |
  | `expires_at` | `utc_datetime_usec` | no |

  Indexes: the unique `<table>_binding_id_message_id_index` on
  `(binding_id, message_id)`, and `<table>_expires_at_index` on
  `expires_at`, for the reaper that deletes expired rows.

  **`routing_ledger`** (ADR-0004, section 4): append-only, one row per
  recorded outcome.

  | Column | Type | Null |
  |---|---|---|
  | `id` | `bigserial`, primary key | no |
  | `binding_id` | `text` | no |
  | `message_id` | `text` | no |
  | `scope` | `text` | no |
  | `outcome` | `text` | no |
  | `key` | `text` | yes, empty for key_refused |
  | `execution_id` | `text` | yes, empty where the outcome names no execution |
  | `reason` | `text` | yes, empty for every outcome but key_refused |
  | `inserted_at` | `utc_datetime_usec` | no |

  Index: `<table>_binding_id_inserted_at_index` on `(binding_id,
  inserted_at)`, since the ledger is read per binding.

  The tables above are the layout with no layout option set. The
  `StatifierRouter.Migrations` layout options reshape them only as this
  version creates them: `:leading_columns` go immediately after `id` on
  all three, `timestamps_position: :leading` moves `inserted_at` to
  follow them on the two tables that have one, and `:column_collations`
  declares each named text column with its collation wherever a table
  here has it.
  """

  use Ecto.Migration

  alias StatifierRouter.Config

  @typedoc "The resolved storage options `StatifierRouter.Migrations` hands each version."
  @type storage :: %{
          required(:table_prefix) => String.t(),
          required(:prefix) => String.t() | nil,
          optional(:leading_columns) => [{atom(), {term(), keyword()}}],
          optional(:timestamps_position) => :trailing | :leading,
          optional(:column_collations) => [{atom(), String.t()}]
        }

  @doc "Creates the V01 tables and their indexes."
  @spec up(storage()) :: :ok
  def up(%{table_prefix: table_prefix, prefix: prefix} = storage) do
    if prefix do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    end

    addresses = Config.table_name(table_prefix, :addresses)

    create table(addresses, prefix: prefix) do
      add_leading_columns(storage)
      add_inserted_at(storage, :leading)
      add(:scope, :text, collated(storage, :scope, null: false))
      add(:document, :text, collated(storage, :document, null: false))
      add(:key, :text, collated(storage, :key, null: false))
      add(:execution_id, :text, collated(storage, :execution_id, null: false))
      add_inserted_at(storage, :trailing)
      add(:terminal_seen_at, :utc_datetime_usec, null: true)
    end

    create(
      unique_index(addresses, [:scope, :document, :key],
        name: "#{addresses}_scope_document_key_index",
        prefix: prefix
      )
    )

    create(
      index(addresses, [:execution_id], name: "#{addresses}_execution_id_index", prefix: prefix)
    )

    dedupe = Config.table_name(table_prefix, :dedupe)

    create table(dedupe, prefix: prefix) do
      add_leading_columns(storage)
      add(:binding_id, :text, collated(storage, :binding_id, null: false))
      add(:message_id, :text, collated(storage, :message_id, null: false))
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(dedupe, [:binding_id, :message_id],
        name: "#{dedupe}_binding_id_message_id_index",
        prefix: prefix
      )
    )

    create(index(dedupe, [:expires_at], name: "#{dedupe}_expires_at_index", prefix: prefix))

    ledger = Config.table_name(table_prefix, :routing_ledger)

    create table(ledger, prefix: prefix) do
      add_leading_columns(storage)
      add_inserted_at(storage, :leading)
      add(:binding_id, :text, collated(storage, :binding_id, null: false))
      add(:message_id, :text, collated(storage, :message_id, null: false))
      add(:scope, :text, collated(storage, :scope, null: false))
      add(:outcome, :text, collated(storage, :outcome, null: false))
      add(:key, :text, collated(storage, :key, null: true))
      add(:execution_id, :text, collated(storage, :execution_id, null: true))
      add(:reason, :text, collated(storage, :reason, null: true))
      add_inserted_at(storage, :trailing)
    end

    create(
      index(ledger, [:binding_id, :inserted_at],
        name: "#{ledger}_binding_id_inserted_at_index",
        prefix: prefix
      )
    )

    :ok
  end

  # Called first inside a `create table` block, right after the implicit
  # `id`: `add/3` appends to the table being created, so the host's columns
  # land at positions 2..n, in the order given.
  defp add_leading_columns(storage) do
    for {name, {type, opts}} <- Map.get(storage, :leading_columns, []),
        do: add(name, type, opts)
  end

  # Called twice in a table that has `inserted_at`: once after the leading
  # columns and once where the package's layout puts it. Only the call
  # whose position matches the configured one adds the column.
  defp add_inserted_at(storage, position) do
    if Map.get(storage, :timestamps_position, :trailing) == position,
      do: add(:inserted_at, :utc_datetime_usec, null: false)
  end

  # The `add/3` opts for a package text column, carrying the collation
  # `:column_collations` names for it, if any.
  defp collated(storage, name, opts) do
    case Keyword.fetch(Map.get(storage, :column_collations, []), name) do
      {:ok, collation} -> Keyword.put(opts, :collation, collation)
      :error -> opts
    end
  end

  @doc "Drops the V01 tables in reverse creation order; the Postgres schema stays."
  @spec down(storage()) :: :ok
  def down(%{table_prefix: table_prefix, prefix: prefix}) do
    for name <- [:routing_ledger, :dedupe, :addresses] do
      drop(table(Config.table_name(table_prefix, name), prefix: prefix))
    end

    :ok
  end
end
