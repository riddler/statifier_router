defmodule StatifierRouter.SQLiteReapTest do
  # StatifierRouter.Addresses.reap/3 on SQLite, through ecto_sqlite3,
  # against a database file of each test's own, under the default key and
  # under a text key built with the :primary_key option. The execution
  # statuses come from StatifierRouter.StatusStore: the repo holds only the
  # router's tables. In the :sqlite_repo group with
  # StatifierRouter.SQLiteMigrationsTest: both start the one repo process.
  use ExUnit.Case, async: true, group: :sqlite_repo

  import Ecto.Query, only: [from: 2]

  alias Ecto.Migrator
  alias StatifierPersistence.Storage
  alias StatifierRouter.Addresses
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.SQLiteRepo

  # A host on SQLite under the repo's default key.
  defmodule MigrateIntegerKey do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up()
    def down, do: StatifierRouter.Migrations.down()
  end

  # A host on SQLite under a text key the database fills in. The ids are
  # made of digits alone and lead with a zero, so a reap that cast one to
  # an integer would lose the zero and match no row of the text column.
  defmodule MigrateTextKey do
    @moduledoc false
    use Ecto.Migration

    def up do
      StatifierRouter.Migrations.up(
        primary_key: [
          type: :text,
          default: fragment("(printf('0%011d', abs(random()) % 100000000000))")
        ]
      )
    end

    def down, do: StatifierRouter.Migrations.down()
  end

  @version 20_260_930_000_501

  @now ~U[2026-09-30 12:00:00.000000Z]
  @hour 3_600_000

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

  # Five parcels, one address row each: two delivered, one still on the
  # van, one whose execution the store no longer holds, and one delivered
  # and already stamped a day ago.
  @statuses %{
    "ex_pcl_6001" => :completed,
    "ex_pcl_6002" => :completed,
    "ex_pcl_6003" => :active,
    "ex_pcl_6005" => :completed
  }

  defp config do
    {:ok, config} =
      Config.new(
        repo: SQLiteRepo,
        delivery: StatifierRouter.RecordingDelivery,
        store: %Storage{adapter: StatifierRouter.StatusStore, opts: @statuses}
      )

    config
  end

  defp seed do
    rows =
      for n <- 6001..6005 do
        %{
          scope: "depot_north",
          document: "parcel_delivery",
          key: "pcl_#{n}",
          execution_id: "ex_pcl_#{n}",
          inserted_at: @now,
          terminal_seen_at: if(n == 6005, do: DateTime.add(@now, -24 * @hour, :millisecond))
        }
      end

    {5, _} = SQLiteRepo.insert_all(Address, rows)
    :ok
  end

  # The reap's answer, or the message of what it raised, so a statement
  # the adapter refuses fails the assertion that names it.
  defp reap(config, bindings, opts) do
    Addresses.reap(config, bindings, opts)
  rescue
    error in Exqlite.Error -> {:raised, Exception.message(error)}
  end

  # key => terminal_seen_at, for every address row left.
  defp addresses(config) do
    config
    |> Config.queryable(Address)
    |> then(&from(a in &1, select: {a.key, a.terminal_seen_at}))
    |> SQLiteRepo.all()
    |> Map.new()
  end

  @doc false
  # Runs in the process that sent the query, so a statement this test's
  # own process sent is the only one it is told about.
  def handle_query(_event, _measurements, %{query: query}, test) do
    if self() == test, do: send(test, {:query, query})
  end

  # Every UPDATE or DELETE statement this test sent, in order.
  defp writes do
    receive do
      {:query, "UPDATE " <> _ = query} -> [query | writes()]
      {:query, "DELETE " <> _ = query} -> [query | writes()]
      {:query, _other} -> writes()
    after
      0 -> []
    end
  end

  defp ids(config) do
    SQLiteRepo.all(from(a in Config.queryable(config, Address), select: a.id))
  end

  # The delivered-scan binding, whose horizon keeps a delivered parcel's
  # row for an hour after a reap first sees it delivered.
  defp bindings do
    {:ok, binding} =
      Binding.new(%{
        id: "delivered_scans",
        source: "depot_scans",
        match: "event.kind == 'delivered'",
        key: "event.parcel_id",
        document: "parcel_delivery",
        event: "delivered",
        data: ["parcel_id"],
        dedupe: %{by: :message_id, horizon_ms: @hour}
      })

    [binding]
  end

  # The same reap, twice: the first stamps the two parcels it is the first
  # to see delivered and deletes the orphan and the row stamped a day ago;
  # the second, an hour on, deletes the two it stamped.
  defp sweep(config) do
    assert reap(config, bindings(), now: @now) ==
             {:ok, %{stamped: 2, deleted: 2, next: nil}}

    assert addresses(config) == %{
             "pcl_6001" => @now,
             "pcl_6002" => @now,
             "pcl_6003" => nil
           }

    an_hour_on = DateTime.add(@now, @hour, :millisecond)

    assert reap(config, bindings(), now: an_hour_on) ==
             {:ok, %{stamped: 0, deleted: 2, next: nil}}

    assert addresses(config) == %{"pcl_6003" => nil}
  end

  describe "reap/3 on SQLite" do
    # sabotage: put back stamp/3's and delete/2's `? = ANY(?)` fragment ->
    # red, the first reap raised "no such function: ANY".
    test "stamps and deletes under the default integer key" do
      :ok = Migrator.up(SQLiteRepo, @version, MigrateIntegerKey, log: false)
      config = config()
      :ok = seed()

      assert Enum.all?(ids(config), &is_integer/1)
      sweep(config)
    end

    # sabotage: cast every id to an integer before it was bound in stamp/3
    # and delete/2 -> red, the first reap stamped and deleted nothing.
    test "stamps and deletes under a text key of digits, bound uncast" do
      :ok = Migrator.up(SQLiteRepo, @version, MigrateTextKey, log: false)
      config = config()
      :ok = seed()

      assert Enum.all?(ids(config), &(is_binary(&1) and &1 =~ ~r/^0\d{11}$/))
      sweep(config)
    end

    # sabotage: made postgres?/1 answer true, so stamp/3 and delete/2 took
    # the `? = ANY(?)` array form on SQLite -> red, the first reap raised
    # "no such function: ANY" instead of stamping; restored, green.
    test "binds each batch of ids as a spliced IN list" do
      :ok = Migrator.up(SQLiteRepo, @version, MigrateIntegerKey, log: false)
      config = config()
      :ok = seed()

      handler = "sqlite-reap-#{System.unique_integer([:positive])}"
      query = SQLiteRepo.config()[:telemetry_prefix] ++ [:query]
      :ok = :telemetry.attach(handler, query, &__MODULE__.handle_query/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)

      sweep(config)

      assert [_stamp, _delete_now, _delete_later] = statements = writes()

      for statement <- statements do
        assert statement =~ " IN ("
        refute statement =~ "ANY("
      end
    end
  end

  describe "reap/3 on SQLite, past one statement's batch of ids" do
    # sabotage: in_batches/2 answered the last batch's count alone -> red,
    # the first reap answered stamped: 201 for 1201 rows stamped.
    test "stamps and deletes every row of a reap that examines more ids than one statement binds" do
      :ok = Migrator.up(SQLiteRepo, @version, MigrateIntegerKey, log: false)
      numbers = 7001..8201
      statuses = Map.new(numbers, &{"ex_pcl_#{&1}", :completed})

      {:ok, config} =
        Config.new(
          repo: SQLiteRepo,
          delivery: StatifierRouter.RecordingDelivery,
          store: %Storage{adapter: StatifierRouter.StatusStore, opts: statuses}
        )

      for chunk <- Enum.chunk_every(numbers, 100) do
        rows =
          for n <- chunk do
            %{
              scope: "depot_north",
              document: "parcel_delivery",
              key: "pcl_#{n}",
              execution_id: "ex_pcl_#{n}",
              inserted_at: @now
            }
          end

        SQLiteRepo.insert_all(Address, rows)
      end

      assert reap(config, bindings(), now: @now, limit: 2_000) ==
               {:ok, %{stamped: 1201, deleted: 0, next: nil}}

      assert addresses(config) |> Map.values() |> Enum.uniq() == [@now]

      an_hour_on = DateTime.add(@now, @hour, :millisecond)

      assert reap(config, bindings(), now: an_hour_on, limit: 2_000) ==
               {:ok, %{stamped: 0, deleted: 1201, next: nil}}

      assert addresses(config) == %{}
    end
  end
end
