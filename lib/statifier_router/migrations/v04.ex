defmodule StatifierRouter.Migrations.V04 do
  @moduledoc """
  V04 of the package DDL: the location table, which holds the BasicHTTP
  location token of each address row a configuration with `:basichttp`
  mints one for (ADR-0002, the Amendment of 2026-09-30, decision 1). It
  is named by `StatifierRouter.Config.table/2` under the host's table
  prefix and created in the host's Postgres schema when one is set.

  **`locations`**:

  | Column | Type | Null |
  |---|---|---|
  | `id` | `bigserial`, primary key | no |
  | `address_id` | the address table's key type, referencing its `id`, `ON DELETE CASCADE` | no |
  | `token` | `text` | no |
  | `inserted_at` | `utc_datetime_usec` | no |

  Indexes: the unique `<table>_address_id_index` on `address_id`, one
  location per address row, and the unique `<table>_token_index` on
  `token`, which the front reads a location by.

  The reference cascades, so a row `StatifierRouter.Addresses.reap/2`
  deletes takes its location with it, and a delivery that rolls back its
  address row rolls back its location too.

  A table of its own rather than a column on the address table: the
  package reads and writes it only on a configuration that sets
  `:basichttp`, so a host that does not use BasicHTTP never needs this
  version, and a host that runs it and leaves the key unset gets an
  empty table nothing reads.

  The layout options and `:primary_key` of `StatifierRouter.Migrations`
  apply here on V01's terms: `:leading_columns` go immediately after
  `id`, `timestamps_position: :leading` moves `inserted_at` to follow
  them, and `:primary_key` types this table's `id` and the `address_id`
  reference alike, so a host that built V01 under `:primary_key` passes
  the same option here. Without it, the reference takes the repo's own
  foreign key type, which matches the address table's `id` when V01 was
  built without the option too.

  **V04 is opt-in, outside the version walk.** `StatifierRouter.Migrations.up/1`
  and `down/1` never run it, capped or not, so a host that never sets
  `:basichttp` sees every migration answer as before V04 existed. A host
  that sets the key runs it through `StatifierRouter.Migrations.up_locations/1`
  and `StatifierRouter.Migrations.down_locations/1` (that module's "The
  location table, V04, is opt-in"), as ADR-0002, the Amendment of
  2026-09-30 "the location table is opt-in, outside the version walk",
  decides.

  `up/1` creates the table and its indexes only where they do not exist
  yet, and `down/1` drops the table only if it is there, as V03 renames
  only what it finds. Because the table references the address table, it
  has to be dropped before V01's tables are: a host's migration that runs
  `up_locations/1` rolls back before the migration that created them.
  """

  use Ecto.Migration

  alias StatifierRouter.Config

  @typedoc "The resolved storage and layout options `StatifierRouter.Migrations` hands each version."
  @type storage :: %{
          required(:table_prefix) => String.t(),
          required(:prefix) => String.t() | nil,
          optional(:leading_columns) => [{atom(), {term(), keyword()}}],
          optional(:timestamps_position) => :trailing | :leading,
          optional(:column_collations) => [{atom(), String.t()}],
          optional(:primary_key) => keyword() | nil
        }

  @doc "Creates the V04 table and its indexes."
  @spec up(storage()) :: :ok
  def up(%{table_prefix: table_prefix, prefix: prefix} = storage) do
    if prefix do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
    end

    addresses = Config.table_name(table_prefix, :addresses)
    locations = Config.table_name(table_prefix, :locations)

    create_if_not_exists table(locations, table_opts(storage)) do
      add_leading_columns(storage)
      add_inserted_at(storage, :leading)
      add(:address_id, references(addresses, reference_opts(storage)), null: false)
      add(:token, :text, null: false)
      add_inserted_at(storage, :trailing)
    end

    create_if_not_exists(
      unique_index(locations, [:address_id],
        name: "#{locations}_address_id_index",
        prefix: prefix
      )
    )

    create_if_not_exists(
      unique_index(locations, [:token], name: "#{locations}_token_index", prefix: prefix)
    )

    :ok
  end

  @doc "Drops the V04 table if it is there; the Postgres schema and the earlier tables stay."
  @spec down(storage()) :: :ok
  def down(%{table_prefix: table_prefix, prefix: prefix}) do
    drop_if_exists(table(Config.table_name(table_prefix, :locations), prefix: prefix))

    :ok
  end

  # The table/2 opts, as V01's: the Postgres schema, and the host's primary
  # key when :primary_key names one.
  defp table_opts(%{prefix: prefix} = storage) do
    case Map.get(storage, :primary_key) do
      nil -> [prefix: prefix]
      primary_key -> [prefix: prefix, primary_key: [name: :id] ++ primary_key]
    end
  end

  # The reference to the address row's id: the key type :primary_key
  # names when it is set, and otherwise the repo's own foreign key type.
  defp reference_opts(%{prefix: prefix} = storage) do
    base = [column: :id, on_delete: :delete_all, prefix: prefix]

    case Map.get(storage, :primary_key) do
      nil -> base
      primary_key -> Keyword.put(base, :type, Keyword.fetch!(primary_key, :type))
    end
  end

  # The same helpers as V01's, kept per version: a version's DDL reads
  # whole in its own file.
  defp add_leading_columns(storage) do
    for {name, {type, opts}} <- Map.get(storage, :leading_columns, []),
        do: add(name, type, opts)
  end

  defp add_inserted_at(storage, position) do
    if Map.get(storage, :timestamps_position, :trailing) == position,
      do: add(:inserted_at, :utc_datetime_usec, null: false)
  end
end
