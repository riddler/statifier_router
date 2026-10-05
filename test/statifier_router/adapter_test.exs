defmodule StatifierRouter.AdapterTest do
  # Which repos the private StatifierRouter.Adapter helper reads as SQLite:
  # the stock SQLite adapter module, a module that is not the stock one but
  # writes its SQL with the stock SQLite connection, and never a Postgres
  # repo or a repo module that names no adapter. The SQLite repo processes
  # run under their module names, so this module is in the :sqlite_repo
  # group, whose modules never run at once; it opens no sandbox connection.
  use ExUnit.Case, async: true, group: :sqlite_repo

  alias StatifierRouter.Adapter
  alias StatifierRouter.SQLiteRepo
  alias StatifierRouter.TestRepo
  alias StatifierRouter.WrappedPostgresRepo
  alias StatifierRouter.WrappedSQLiteRepo

  # A repo module that delegates to TestRepo rather than being an Ecto
  # repo: it exports no __adapter__/0, so it names no adapter.
  defmodule DelegatingRepo do
    @moduledoc false

    alias StatifierRouter.TestRepo

    def all(queryable), do: TestRepo.all(queryable)
  end

  defp start_wrapped_sqlite do
    database =
      Path.join(
        System.tmp_dir!(),
        "statifier_router_adapter_#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({WrappedSQLiteRepo, database: database, pool_size: 1})

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)
  end

  defp start_wrapped_postgres do
    connection =
      Keyword.take(TestRepo.config(), [:hostname, :port, :username, :password, :database])

    start_supervised!({WrappedPostgresRepo, connection ++ [pool_size: 1]})
  end

  describe "sqlite?/1" do
    # The repo is not started: the stock module answers on its own, without
    # asking a running repo.
    #
    # sabotage: made the Ecto.Adapters.SQLite3 clause answer false -> red,
    # the assertion read false; restored, green.
    test "is true for a repo on the stock SQLite adapter module" do
      assert SQLiteRepo.__adapter__() == Ecto.Adapters.SQLite3
      assert Adapter.sqlite?(SQLiteRepo)
    end

    # sabotage: made the clause for any other adapter module answer false
    # -> red, the assertion read false; restored, green.
    test "is true for an adapter module that is not the stock one but writes with SQLite's connection" do
      start_wrapped_sqlite()

      assert WrappedSQLiteRepo.__adapter__() == StatifierRouter.WrappedSQLite3
      assert Adapter.sqlite?(WrappedSQLiteRepo)
      refute Adapter.postgres?(WrappedSQLiteRepo)
    end

    # sabotage: made the clause for any other adapter module answer true
    # -> red, the wrapped Postgres repo read as SQLite; restored, green.
    test "is false for a Postgres repo, on the stock adapter module or a wrapper of it" do
      start_wrapped_postgres()

      refute Adapter.sqlite?(TestRepo)
      assert WrappedPostgresRepo.__adapter__() == StatifierRouter.WrappedPostgres
      refute Adapter.sqlite?(WrappedPostgresRepo)

      # postgres?/1 reads the stock module alone, as before.
      assert Adapter.postgres?(TestRepo)
      refute Adapter.postgres?(WrappedPostgresRepo)
    end

    # sabotage: made the clause for a repo naming no adapter answer true
    # -> red, the assertion read true; restored, green.
    test "is false for a repo module that exports no __adapter__/0" do
      refute function_exported?(DelegatingRepo, :__adapter__, 0)
      assert Adapter.adapter(DelegatingRepo) == nil
      refute Adapter.sqlite?(DelegatingRepo)
    end
  end
end
