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

  The table above is the layout with no layout option set. The
  `StatifierRouter.Migrations` layout options reshape it only as this
  version creates it, on the same terms as V01's tables: the
  `:leading_columns` immediately after `id`, `inserted_at` following them
  under `timestamps_position: :leading`, and each text column
  `:column_collations` names declared with its collation. A table V01
  already created is not touched.

  A host that has already run V01 reaches this version with
  `StatifierRouter.Migrations.up(from: 2)`: `from:` names the first
  version the host has **not** run and the walk includes it.
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

  @doc "Creates the V02 table and its index."
  @spec up(storage()) :: :ok
  def up(%{table_prefix: table_prefix, prefix: prefix} = storage) do
    if prefix do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    end

    subscriptions = Config.table_name(table_prefix, :subscriptions)

    create table(subscriptions, prefix: prefix) do
      add_leading_columns(storage)
      add_inserted_at(storage, :leading)
      add(:binding_id, :text, collated(storage, :binding_id, null: false))
      add(:execution_id, :text, collated(storage, :execution_id, null: false))
      add(:invoke_id, :text, collated(storage, :invoke_id, null: false))
      add(:scope, :text, collated(storage, :scope, null: false))
      add(:key, :text, collated(storage, :key, null: false))
      add_inserted_at(storage, :trailing)
    end

    create(
      unique_index(subscriptions, [:execution_id, :binding_id, :invoke_id],
        name: "#{subscriptions}_execution_id_binding_id_invoke_id_index",
        prefix: prefix
      )
    )

    :ok
  end

  # The same three helpers as V01's, kept per version as
  # statifier_persistence keeps them: a version's DDL reads whole in its
  # own file.
  defp add_leading_columns(storage) do
    for {name, {type, opts}} <- Map.get(storage, :leading_columns, []),
        do: add(name, type, opts)
  end

  defp add_inserted_at(storage, position) do
    if Map.get(storage, :timestamps_position, :trailing) == position,
      do: add(:inserted_at, :utc_datetime_usec, null: false)
  end

  defp collated(storage, name, opts) do
    case Keyword.fetch(Map.get(storage, :column_collations, []), name) do
      {:ok, collation} -> Keyword.put(opts, :collation, collation)
      :error -> opts
    end
  end

  @doc "Drops the V02 table; the Postgres schema and the V01 tables stay."
  @spec down(storage()) :: :ok
  def down(%{table_prefix: table_prefix, prefix: prefix}) do
    drop(table(Config.table_name(table_prefix, :subscriptions), prefix: prefix))

    :ok
  end
end
