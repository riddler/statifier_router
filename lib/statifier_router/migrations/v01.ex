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
  """

  use Ecto.Migration

  alias StatifierRouter.Config

  @typedoc "The resolved storage options `StatifierRouter.Migrations` hands each version."
  @type storage :: %{table_prefix: String.t(), prefix: String.t() | nil}

  @doc "Creates the V01 tables and their indexes."
  @spec up(storage()) :: :ok
  def up(%{table_prefix: table_prefix, prefix: prefix}) do
    if prefix do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    end

    addresses = Config.table_name(table_prefix, :addresses)

    create table(addresses, prefix: prefix) do
      add(:scope, :text, null: false)
      add(:document, :text, null: false)
      add(:key, :text, null: false)
      add(:execution_id, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
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
      add(:binding_id, :text, null: false)
      add(:message_id, :text, null: false)
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
      add(:binding_id, :text, null: false)
      add(:message_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:outcome, :text, null: false)
      add(:key, :text, null: true)
      add(:execution_id, :text, null: true)
      add(:reason, :text, null: true)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      index(ledger, [:binding_id, :inserted_at],
        name: "#{ledger}_binding_id_inserted_at_index",
        prefix: prefix
      )
    )

    :ok
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
