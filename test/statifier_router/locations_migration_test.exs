defmodule StatifierRouter.LocationsMigrationTest do
  # The opt-in location table (V04) through a host's own migrations, under
  # a table prefix and a Postgres schema of this module's own. Live DDL
  # outside the SQL sandbox, like migrations_test.exs: setup switches the
  # repo to :auto and restores :manual on exit, hence async: false and the
  # :isolated tag (test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :isolated

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.Config
  alias StatifierRouter.Migrations
  alias StatifierRouter.Schema.{Address, Location}
  alias StatifierRouter.TestRepo

  @schema "loc_router_schema"

  # The first migration every host already has, uncapped both ways, as the
  # Migrations moduledoc shows it.
  defmodule MigrateFirst do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "loc_router_", prefix: "loc_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  # The migration the README and the Migrations moduledoc give a host that
  # sets :basichttp, written after the first.
  defmodule MigrateLocations do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "loc_router_", prefix: "loc_router_schema"]

    def up, do: StatifierRouter.Migrations.up_locations(@opts)
    def down, do: StatifierRouter.Migrations.down_locations(@opts)
  end

  # A host that opts in from its one first migration: V01 to V03 and the
  # location table up, and back down in the reverse order.
  defmodule MigrateOptedIn do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "loc_router_", prefix: "loc_router_schema"]

    def up do
      StatifierRouter.Migrations.up(@opts)
      StatifierRouter.Migrations.up_locations(@opts)
    end

    def down do
      StatifierRouter.Migrations.down_locations(@opts)
      StatifierRouter.Migrations.down(@opts)
    end
  end

  # down_locations/1 alone, on a database that never ran up_locations/1.
  defmodule MigrateLocationsDownOnly do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "loc_router_", prefix: "loc_router_schema"]

    def up, do: StatifierRouter.Migrations.down_locations(@opts)
    def down, do: :ok
  end

  # Dated past every bootstrap and migrations_test version, so Ecto never
  # warns that one sorts below a version already run.
  @first_version 29_990_201_000_101
  @locations_version 29_990_201_000_102
  @opted_in_version 29_990_201_000_103
  @down_only_version 29_990_201_000_104
  @versions [@first_version, @locations_version, @opted_in_version, @down_only_version]

  @walk_tables [
    "loc_router_addresses",
    "loc_router_dedupe",
    "loc_router_routing_ledger",
    "loc_router_subscriptions"
  ]
  @all_tables Enum.sort(["loc_router_locations" | @walk_tables])

  setup do
    Sandbox.mode(TestRepo, :auto)
    clear()

    on_exit(fn ->
      clear()
      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  # This module's schema is its own, so dropping it whole is safe.
  defp clear do
    SQL.query!(TestRepo, ~s(DROP SCHEMA IF EXISTS "#{@schema}" CASCADE), [])
    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [@versions])
    :ok
  end

  # A migration step's answer, or what it raised, so a refused rollback
  # fails an assertion rather than the test's own process.
  defp step(direction, version, module) do
    apply(Migrator, direction, [TestRepo, version, module, [log: false]])
  rescue
    error -> {:raised, error}
  end

  defp tables_present do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = $1 ORDER BY table_name",
        [@schema]
      )

    List.flatten(rows)
  end

  defp config do
    {:ok, config} =
      Config.new(
        repo: TestRepo,
        delivery: StatifierRouter.RecordingDelivery,
        table_prefix: "loc_router_",
        prefix: @schema
      )

    config
  end

  # sabotage: put V04 back in @migrations, so the uncapped walk reached
  # it -> up/1 created loc_router_locations, red on the first table list;
  # restored, green.
  test "an uncapped first migration never creates V04, and rolls a pre-V04 database back whole" do
    assert step(:up, @first_version, MigrateFirst) == :ok
    assert tables_present() == @walk_tables

    assert step(:down, @first_version, MigrateFirst) == :ok
    assert tables_present() == []
  end

  # sabotage: V04.down/1 made to drop nothing -> the location table was
  # still there after its migration rolled back, red; restored, green.
  test "the documented opt-in migration rolls back before the first, and the database empties" do
    assert step(:up, @first_version, MigrateFirst) == :ok
    assert step(:up, @locations_version, MigrateLocations) == :ok
    assert tables_present() == @all_tables

    assert step(:down, @locations_version, MigrateLocations) == :ok
    assert tables_present() == @walk_tables

    assert step(:down, @first_version, MigrateFirst) == :ok
    assert tables_present() == []
  end

  # sabotage: V04's reference made on_delete: :nothing -> deleting the
  # address row was refused and the location outlived it, red; restored,
  # green. sabotage: V04's token index made a plain index -> the second
  # token insert succeeded, red; restored, green.
  test "a host that opts in from one migration gets the cascade and the unique token, and rolls back whole" do
    assert step(:up, @opted_in_version, MigrateOptedIn) == :ok
    assert tables_present() == @all_tables

    config = config()

    [first, second] =
      for key <- ["pcl_4821", "pcl_5190"] do
        TestRepo.insert!(
          Config.put_meta(config, %Address{
            scope: "7c1e",
            document: "parcel_route",
            key: key,
            execution_id: "ex_" <> key
          })
        )
      end

    location =
      TestRepo.insert!(Config.put_meta(config, %Location{address_id: first.id, token: "tok_1"}))

    duplicate =
      try do
        TestRepo.insert!(
          Config.put_meta(config, %Location{address_id: second.id, token: "tok_1"})
        )
      rescue
        error in Ecto.ConstraintError -> {:refused, error.constraint}
      end

    assert duplicate == {:refused, "loc_router_locations_token_index"}

    deleted =
      try do
        TestRepo.delete!(Config.put_meta(config, first))
      rescue
        error -> {:raised, error}
      end

    assert %Address{} = deleted
    assert TestRepo.get(Config.queryable(config, Location), location.id) == nil

    assert step(:down, @opted_in_version, MigrateOptedIn) == :ok
    assert tables_present() == []
  end

  # sabotage: V04.down/1 made drop/1 again, not drop_if_exists/1 -> the
  # call raised on the missing table, red; restored, green.
  test "down_locations/1 on a database that never ran V04 does nothing" do
    assert step(:up, @first_version, MigrateFirst) == :ok
    assert step(:up, @down_only_version, MigrateLocationsDownOnly) == :ok
    assert tables_present() == @walk_tables
  end

  # sabotage: up_locations/1 made to skip refuse_location_column_names!/2
  # -> the call reached the DDL outside a migration runner and raised
  # another error, red on assert_raise; restored, green.
  test "up_locations/1 refuses a leading column the location table declares, and a version" do
    for name <- [:address_id, :token, :inserted_at] do
      assert_raise ArgumentError, ~r/#{inspect(name)} \(in locations\)/, fn ->
        Migrations.up_locations(leading_columns: [{name, {:text, []}}])
      end
    end

    assert_raise ArgumentError, ~r/:id \(in locations\)/, fn ->
      Migrations.up_locations(leading_columns: [id: {:text, []}], primary_key: [type: :text])
    end

    for option <- [from: 4, version: 4] do
      assert_raise ArgumentError, ~r/unknown_key/, fn -> Migrations.up_locations([option]) end
      assert_raise ArgumentError, ~r/unknown_key/, fn -> Migrations.down_locations([option]) end
    end
  end
end
