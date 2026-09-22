defmodule StatifierRouter.Migrations.V02 do
  @moduledoc """
  V02 of the package DDL: the subscription table ADR-0007, section 6 fixes,
  named by `StatifierRouter.Config.table/2` under the host's table prefix
  and created in the host's Postgres schema when one is set.

  **`subscriptions`** (ADR-0007, section 6): one row per live source
  invocation, written by `StatifierRouter.subscribe/3` and deleted by
  `StatifierRouter.cancel/2`.

  | Column | Type | Null |
  |---|---|---|
  | `id` | `bigserial`, primary key | no |
  | `binding_id` | `text` | no |
  | `execution_id` | `text` | no |
  | `invoke_id` | `text` | no |
  | `scope` | `text` | no |
  | `key` | `text` | no |
  | `inserted_at` | `utc_datetime_usec` | no |

  Every column is `null: false`, the shape V01's address table already
  uses for everything but its terminal timestamp: a subscription with no
  key is the refusal ADR-0007, section 6 names rather than a row.

  Index: the unique
  `<table>_execution_id_binding_id_invoke_id_index` on `(execution_id,
  binding_id, invoke_id)`. That triple is the identity ADR-0007,
  section 6 asks the row to distinguish - "two invocations of the same
  binding in one execution do not cancel each other" - and its leading
  column is the one `StatifierRouter.SourceInvoke` reads a row back by,
  since the engine's cancellation carries an `invoke_id` and an execution
  and no binding.

  A host that has already run V01 reaches this version with
  `StatifierRouter.Migrations.up(from: 2)`: `from:` names the first
  version the host has **not** run and the walk includes it.
  """

  use Ecto.Migration

  alias StatifierRouter.Config

  @typedoc "The resolved storage options `StatifierRouter.Migrations` hands each version."
  @type storage :: %{table_prefix: String.t(), prefix: String.t() | nil}

  @doc "Creates the V02 table and its index."
  @spec up(storage()) :: :ok
  def up(%{table_prefix: table_prefix, prefix: prefix}) do
    if prefix do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    end

    subscriptions = Config.table_name(table_prefix, :subscriptions)

    create table(subscriptions, prefix: prefix) do
      add(:binding_id, :text, null: false)
      add(:execution_id, :text, null: false)
      add(:invoke_id, :text, null: false)
      add(:scope, :text, null: false)
      add(:key, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(subscriptions, [:execution_id, :binding_id, :invoke_id],
        name: "#{subscriptions}_execution_id_binding_id_invoke_id_index",
        prefix: prefix
      )
    )

    :ok
  end

  @doc "Drops the V02 table; the Postgres schema and the V01 tables stay."
  @spec down(storage()) :: :ok
  def down(%{table_prefix: table_prefix, prefix: prefix}) do
    drop(table(Config.table_name(table_prefix, :subscriptions), prefix: prefix))

    :ok
  end
end
