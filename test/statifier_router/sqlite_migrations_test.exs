defmodule StatifierRouter.SQLiteMigrationsTest do
  # The version walk on SQLite, through ecto_sqlite3, against a database
  # file of each test's own: no Postgres, no SQL sandbox. The one repo
  # process runs under the module's name, so every module that starts it
  # is in the :sqlite_repo group, whose modules never run at once.
  use ExUnit.Case, async: true, group: :sqlite_repo

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias StatifierRouter.SQLiteRepo
  alias StatifierRouter.WrappedSQLiteRepo

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

  # A repo module that hands every call to SQLiteRepo but exports no
  # __adapter__/0: it names no adapter.
  defmodule NoAdapterRepo do
    @moduledoc false

    for {name, arity} <- StatifierRouter.SQLiteRepo.__info__(:functions),
        {name, arity} != {:__adapter__, 0} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: StatifierRouter.SQLiteRepo.unquote(name)(unquote_splicing(args))
    end
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
  defp migrate(direction, version, module, repo \\ SQLiteRepo) do
    apply(Migrator, direction, [repo, version, module, [log: false]])
  rescue
    error -> {:raised, Exception.message(error)}
  end

  # A second database file, migrated through WrappedSQLiteRepo.
  defp start_wrapped do
    database =
      Path.join(
        System.tmp_dir!(),
        "statifier_router_wrapped_sqlite_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({WrappedSQLiteRepo, database: database, pool_size: 1})

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)
  end

  # name => {unique?, columns in index order}, for every index SQLite
  # holds on the table, the ones it makes for itself left out.
  defp indexes(table, repo \\ SQLiteRepo) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?1 " <>
          "AND name NOT LIKE 'sqlite_autoindex_%'",
        [table]
      )

    Map.new(rows, fn [name] -> {name, index(repo, name)} end)
  end

  defp index(repo, name) do
    %{rows: [[unique]]} =
      SQL.query!(repo, "SELECT \"unique\" FROM pragma_index_list(?1) WHERE name = ?2", [
        @subscriptions,
        name
      ])

    %{rows: columns} =
      SQL.query!(repo, "SELECT name FROM pragma_index_info(?1) ORDER BY seqno", [name])

    {unique == 1, List.flatten(columns)}
  end

  defp router_tables(repo \\ SQLiteRepo) do
    %{rows: rows} =
      SQL.query!(
        repo,
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

  describe "V03 on a SQLite adapter module that is not the stock one" do
    # The repo's adapter module is StatifierRouter.WrappedSQLite3, which
    # hands every callback to Ecto.Adapters.SQLite3: V03 reads the repo as
    # SQLite by the connection that writes its SQL.
    #
    # sabotage: made V03 read SQLite by the stock adapter module alone, as
    # it did before (`repo().__adapter__() != Ecto.Adapters.SQLite3`) ->
    # red, the V03 up raised a syntax error near "INDEX"; restored, green.
    test "leaves V02's index under the whole name SQLite gave it, up and down" do
      start_wrapped()

      assert WrappedSQLiteRepo.__adapter__() == StatifierRouter.WrappedSQLite3
      assert migrate(:up, @through_v02_version, MigrateThroughV02, WrappedSQLiteRepo) == :ok
      v02_indexes = indexes(@subscriptions, WrappedSQLiteRepo)

      assert %{@v02_spelling => {true, ["execution_id", "binding_id", "invoke_id"]}} =
               v02_indexes

      assert migrate(:up, @v03_version, MigrateV03, WrappedSQLiteRepo) == :ok
      assert indexes(@subscriptions, WrappedSQLiteRepo) == v02_indexes

      assert migrate(:down, @v03_version, MigrateV03, WrappedSQLiteRepo) == :ok
      assert indexes(@subscriptions, WrappedSQLiteRepo) == v02_indexes

      assert migrate(:down, @through_v02_version, MigrateThroughV02, WrappedSQLiteRepo) == :ok
      assert router_tables(WrappedSQLiteRepo) == []
    end
  end

  describe "V03 under a repo module that exports no __adapter__/0" do
    # Such a module never reaches V03: Ecto's migrator asks the repo for
    # its adapter itself, before any version runs, and raises. That is
    # the answer V03's own call gave before it read the adapter through
    # the helper, and it is kept.
    #
    # sabotage: not applicable - V03 does not run for this repo, which is
    # what the test pins; a mutation of V03's check leaves it green by
    # construction (run: made V03 call `repo().__adapter__()` again ->
    # green, the migrator raised first).
    test "raises from Ecto's migrator, naming __adapter__/0, before V03 runs" do
      refute function_exported?(NoAdapterRepo, :__adapter__, 0)

      # The migrator logs why it could not create its table, then raises.
      {error, _log} =
        with_log(fn ->
          assert_raise UndefinedFunctionError, fn ->
            Migrator.up(NoAdapterRepo, @v03_version, MigrateV03, log: false)
          end
        end)

      assert %UndefinedFunctionError{module: NoAdapterRepo, function: :__adapter__, arity: 0} =
               error

      assert router_tables() == []
    end
  end
end
