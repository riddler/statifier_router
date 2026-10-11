defmodule StatifierRouter.SQLiteLocationsTest do
  # The whole migration chain on SQLite, through ecto_sqlite3, against a
  # database file of each test's own: V01 to V03 by the version walk in a
  # host's first migration, then the opt-in location table (V04) in its
  # second, up and down, and the location upsert and location/2 between.
  # In the :sqlite_repo group with StatifierRouter.SQLiteMigrationsTest:
  # every module that starts the one repo process is.
  use ExUnit.Case, async: true, group: :sqlite_repo

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Address, Location}
  alias StatifierRouter.SQLiteRepo

  # A host on SQLite at the default table prefix: its first migration,
  # uncapped both ways, walks V01 to V03.
  defmodule MigrateFirst do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up()
    def down, do: StatifierRouter.Migrations.down()
  end

  # The second migration a host that sets :basichttp adds: V04.
  defmodule MigrateLocations do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up_locations()
    def down, do: StatifierRouter.Migrations.down_locations()
  end

  @first_version 20_261_011_000_601
  @locations_version 20_261_011_000_602

  @base_url "https://depot.example/scxml"

  @walk_tables [
    "statifier_router_addresses",
    "statifier_router_dedupe",
    "statifier_router_routing_ledger",
    "statifier_router_subscriptions"
  ]
  @all_tables Enum.sort(["statifier_router_locations" | @walk_tables])

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

  defp router_tables do
    %{rows: rows} =
      SQL.query!(
        SQLiteRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'statifier_router_%'",
        []
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # name => {unique?, columns in index order}, for every index SQLite
  # holds on the location table, the ones it makes for itself left out.
  defp location_indexes do
    %{rows: rows} =
      SQL.query!(
        SQLiteRepo,
        "SELECT name FROM sqlite_master WHERE type = 'index' " <>
          "AND tbl_name = 'statifier_router_locations' " <>
          "AND name NOT LIKE 'sqlite_autoindex_%'",
        []
      )

    Map.new(rows, fn [name] ->
      %{rows: [[unique]]} =
        SQL.query!(
          SQLiteRepo,
          "SELECT \"unique\" FROM pragma_index_list('statifier_router_locations') " <>
            "WHERE name = ?1",
          [name]
        )

      %{rows: columns} =
        SQL.query!(SQLiteRepo, "SELECT name FROM pragma_index_info(?1) ORDER BY seqno", [name])

      {name, {unique == 1, List.flatten(columns)}}
    end)
  end

  # The location table's one foreign key, as {referenced table, from,
  # to, on delete}.
  defp location_foreign_keys do
    %{rows: rows} =
      SQL.query!(
        SQLiteRepo,
        ~s(SELECT "table", "from", "to", on_delete ) <>
          "FROM pragma_foreign_key_list('statifier_router_locations')",
        []
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp config do
    {:ok, config} =
      Config.new(
        repo: SQLiteRepo,
        delivery: StatifierRouter.RecordingDelivery,
        basichttp: [base_url: @base_url]
      )

    config
  end

  # One address row per parcel, as a delivery that created its execution
  # leaves it.
  defp seed(config) do
    for key <- ["pcl_7101", "pcl_7102"] do
      SQLiteRepo.insert!(
        Config.put_meta(config, %Address{
          scope: "depot_north",
          document: "parcel_delivery",
          key: key,
          execution_id: "ex_" <> key,
          inserted_at: ~U[2026-10-11 08:00:00.000000Z]
        })
      )
    end
  end

  # token => address_id, for every row of the location table.
  defp locations(config) do
    config
    |> Config.queryable(Location)
    |> SQLiteRepo.all()
    |> Map.new(&{&1.token, &1.address_id})
  end

  defp token(location), do: String.replace_prefix(location, @base_url <> "/", "")

  describe "V04 through a host's second migration on SQLite" do
    # sabotage: put V04 in the version walk's @migrations -> the uncapped
    # first migration created statifier_router_locations, red on the
    # first table list; restored, green. sabotage: V04's address_id index
    # made a plain index -> the index map read {false, ["address_id"]},
    # red; restored, green. sabotage: V04's token index made a plain
    # index -> the index map read {false, ["token"]}, red; restored,
    # green. sabotage: V04's reference made on_delete:
    # :nothing -> the foreign key read "NO ACTION", red; restored, green.
    # sabotage: V04.down/1 made to drop nothing -> the table was still
    # there after the second migration rolled back, red; restored, green.
    test "creates the location table after V01 to V03, and both migrations roll back whole" do
      # What each of V01 to V03 builds on SQLite is pinned in
      # StatifierRouter.SQLiteMigrationsTest; here the walk is the ground
      # V04 is built on.
      assert migrate(:up, @first_version, MigrateFirst) == :ok
      assert router_tables() == @walk_tables

      assert migrate(:up, @locations_version, MigrateLocations) == :ok
      assert router_tables() == @all_tables

      assert location_indexes() == %{
               "statifier_router_locations_address_id_index" => {true, ["address_id"]},
               "statifier_router_locations_token_index" => {true, ["token"]}
             }

      assert location_foreign_keys() == [
               {"statifier_router_addresses", "address_id", "id", "CASCADE"}
             ]

      assert migrate(:down, @locations_version, MigrateLocations) == :ok
      assert router_tables() == @walk_tables

      assert migrate(:down, @first_version, MigrateFirst) == :ok
      assert router_tables() == []
    end
  end

  describe "the location upsert and location/2 on SQLite" do
    setup do
      assert migrate(:up, @first_version, MigrateFirst) == :ok
      assert migrate(:up, @locations_version, MigrateLocations) == :ok
      :ok
    end

    # sabotage: rotate_location/2's insert made to leave the token as it
    # was on a conflict (on_conflict: :nothing) -> location/2 still read
    # the first token after the second rotation, red; restored, green.
    # sabotage: location/2's join made to match on l.id rather than
    # l.address_id -> a parcel read the other parcel's location, red;
    # restored, green. sabotage: location/2's where on the execution id
    # dropped -> location/2 read another execution's location, red;
    # restored, green.
    test "inserts a location, replaces its token in place, and location/2 reads each" do
      config = config()
      [first, second] = seed(config)

      assert BasicHTTP.location(config, "ex_pcl_7102") == {:error, :no_location}

      # The second parcel's location first, so the location row's id and
      # its address row's id differ.
      assert {:ok, other} = BasicHTTP.rotate_location(config, "ex_pcl_7102")
      assert {:ok, old} = BasicHTTP.rotate_location(config, "ex_pcl_7101")
      assert BasicHTTP.location(config, "ex_pcl_7101") == {:ok, old}
      assert BasicHTTP.location(config, "ex_pcl_7102") == {:ok, other}
      assert BasicHTTP.location(config, "ex_pcl_7199") == {:error, :no_location}

      assert {:ok, new} = BasicHTTP.rotate_location(config, "ex_pcl_7101")
      assert new != old
      assert BasicHTTP.location(config, "ex_pcl_7101") == {:ok, new}

      # One row per address row: the upsert replaced the token, it did
      # not add a row.
      assert locations(config) == %{token(new) => first.id, token(other) => second.id}
    end

    # sabotage: rotate_location/2's no-address branch made to answer
    # {:ok, location} with a minted token -> red on the answer; restored,
    # green.
    test "answers no_address for an execution no address row names, and writes nothing" do
      config = config()
      seed(config)

      assert BasicHTTP.rotate_location(config, "ex_pcl_7199") ==
               {:error, {:no_address, "ex_pcl_7199"}}

      assert BasicHTTP.location(config, "ex_pcl_7199") == {:error, :no_location}
      assert locations(config) == %{}
    end

    # sabotage: V04's reference made on_delete: :nothing -> deleting the
    # address row was refused on its foreign key, red on the delete's
    # answer; restored, green.
    test "a location goes with its address row" do
      config = config()
      [first, _second] = seed(config)

      # SQLite cascades only with foreign keys on, which ecto_sqlite3
      # turns on by default; a change there fails here, not on V04.
      assert %{rows: [[1]]} = SQL.query!(SQLiteRepo, "PRAGMA foreign_keys", [])

      assert {:ok, _location} = BasicHTTP.rotate_location(config, "ex_pcl_7101")

      # The delete's answer, or what it raised, so a refused delete fails
      # the assertion rather than the test's own process.
      deleted =
        try do
          SQLiteRepo.delete!(Config.put_meta(config, first))
        rescue
          error -> {:raised, error}
        end

      assert %Address{} = deleted

      assert BasicHTTP.location(config, "ex_pcl_7101") == {:error, :no_location}
      assert locations(config) == %{}
    end
  end
end
