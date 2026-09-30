defmodule StatifierRouter.SQLiteMigrationsTest do
  # The version walk on SQLite, through ecto_sqlite3, against a database
  # file of each test's own: no Postgres, no SQL sandbox. The one repo
  # process runs under the module's name, so every module that starts it
  # is in the :sqlite_repo group, whose modules never run at once.
  use ExUnit.Case, async: true, group: :sqlite_repo

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias StatifierRouter.SQLiteRepo

  # A host on SQLite at the default table prefix: its migration for V01 and
  # V02, written before V03 existed, and the one it adds for V03.
  defmodule MigrateThroughV02 do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(version: 2)
    def down, do: StatifierRouter.Migrations.down(from: 2)
  end

  defmodule MigrateV03 do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(from: 3)
    def down, do: StatifierRouter.Migrations.down(from: 3, version: 3)
  end

  # A host whose one migration calls up/1 and down/1 with no version.
  defmodule MigrateAll do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up()
    def down, do: StatifierRouter.Migrations.down()
  end

  @through_v02_version 20_260_930_000_401
  @v03_version 20_260_930_000_402
  @all_version 20_260_930_000_403

  @subscriptions "statifier_router_subscriptions"
  @v02_spelling "statifier_router_subscriptions_execution_id_binding_id_invoke_id_index"

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "statifier_router_sqlite_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({SQLiteRepo, database: database, pool_size: 1})

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)

    :ok
  end

  # The migration's result, or the message of what it raised, so a
  # version the adapter refuses fails the assertion that names it.
  defp migrate(direction, version, module) do
    apply(Migrator, direction, [SQLiteRepo, version, module, [log: false]])
  rescue
    error -> {:raised, Exception.message(error)}
  end

  # name => {unique?, columns in index order}, for every index SQLite
  # holds on the table, the ones it makes for itself left out.
  defp indexes(table) do
    %{rows: rows} =
      SQL.query!(
        SQLiteRepo,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?1 " <>
          "AND name NOT LIKE 'sqlite_autoindex_%'",
        [table]
      )

    Map.new(rows, fn [name] -> {name, index(name)} end)
  end

  defp index(name) do
    %{rows: [[unique]]} =
      SQL.query!(SQLiteRepo, "SELECT \"unique\" FROM pragma_index_list(?1) WHERE name = ?2", [
        @subscriptions,
        name
      ])

    %{rows: columns} =
      SQL.query!(SQLiteRepo, "SELECT name FROM pragma_index_info(?1) ORDER BY seqno", [name])

    {unique == 1, List.flatten(columns)}
  end

  defp router_tables do
    %{rows: rows} =
      SQL.query!(
        SQLiteRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'statifier_router_%'",
        []
      )

    rows |> List.flatten() |> Enum.sort()
  end

  describe "V03 on SQLite" do
    # sabotage: made V03 run its ALTER INDEX on every adapter, as it did
    # before it skipped SQLite -> red, the V03 up raised a syntax error
    # near "INDEX".
    test "leaves V02's index under the whole name SQLite gave it, up and down" do
      assert migrate(:up, @through_v02_version, MigrateThroughV02) == :ok

      # SQLite keeps a name whole: V02's 70 bytes, which Postgres would cut
      # to 63 and which V03 renames there.
      assert byte_size(@v02_spelling) == 70
      v02_indexes = indexes(@subscriptions)

      assert %{@v02_spelling => {true, ["execution_id", "binding_id", "invoke_id"]}} =
               v02_indexes

      assert migrate(:up, @v03_version, MigrateV03) == :ok
      assert indexes(@subscriptions) == v02_indexes

      assert migrate(:down, @v03_version, MigrateV03) == :ok
      assert indexes(@subscriptions) == v02_indexes

      assert migrate(:down, @through_v02_version, MigrateThroughV02) == :ok
      assert router_tables() == []
    end

    # sabotage: made V03's down/1 run its ALTER INDEX on every adapter
    # -> red, the rollback raised a syntax error near "INDEX".
    test "is walked by up/1 and down/1 with no version, as a host's first migration" do
      assert migrate(:up, @all_version, MigrateAll) == :ok

      assert router_tables() == [
               "statifier_router_addresses",
               "statifier_router_dedupe",
               "statifier_router_routing_ledger",
               @subscriptions
             ]

      assert %{@v02_spelling => {true, ["execution_id", "binding_id", "invoke_id"]}} =
               indexes(@subscriptions)

      assert migrate(:down, @all_version, MigrateAll) == :ok
      assert router_tables() == []
    end
  end
end
