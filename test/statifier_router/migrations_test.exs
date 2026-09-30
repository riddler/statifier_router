defmodule StatifierRouter.MigrationsTest do
  # Live migration tests manage their own DDL and rows outside the SQL
  # sandbox: setup_all switches the repo to :auto for the module and
  # restores :manual on exit, hence async: false. :auto is repo-global,
  # so the module is also tagged :isolated: the default run excludes it
  # and `mix test --only isolated` runs it alone (test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :isolated

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.Config
  alias StatifierRouter.Migrations
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger, Location, Subscription}
  alias StatifierRouter.TestRepo

  # A host's one-line delegating migration, under a table prefix and a
  # Postgres schema of its own, so these tests never touch the tables the
  # bootstrap created for the rest of the suite.
  defmodule MigrateKxV01 do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [version: 1])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 1, version: 1])
  end

  # What a host already running V01 writes for V02: `from:` names the first
  # version it has not run, and the walk includes it. Capped at V02, as the
  # host wrote it before V03 existed.
  defmodule MigrateKxV02 do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 2, version: 2])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 2, version: 2])
  end

  # And what the same host writes for V03, uncapped, as the V03 upgrade in
  # StatifierRouter.Migrations reads: on a database V01 and V02 built it
  # walks V03 and V04 both.
  defmodule MigrateKxV03 do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 3])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 3, version: 3])
  end

  # And what it writes for V04. After MigrateKxV03's uncapped walk the
  # table is already there, and V04 changes nothing; its down is what drops
  # the table before the earlier versions roll back.
  defmodule MigrateKxV04 do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 4])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 4, version: 4])
  end

  defmodule MigrateKx do
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  # Ecto warns when it runs a migration whose version sorts below one
  # already run, and the suite-wide bootstrap's versions are already run
  # when this module starts. Dated far past any version the bootstrap will
  # take, so every migration here sorts above them; the first test below
  # holds that as the bootstrap gains versions.
  @version 29_990_101_000_201
  @v01_version 29_990_101_000_202
  @v02_version 29_990_101_000_203
  @v03_version 29_990_101_000_204
  @v04_version 29_990_101_000_205
  @schema "kx_router_schema"
  @v01_tables ["kx_router_addresses", "kx_router_dedupe", "kx_router_routing_ledger"]
  @v02_tables ["kx_router_subscriptions"]
  @v04_tables ["kx_router_locations"]
  @tables Enum.sort(@v01_tables ++ @v02_tables ++ @v04_tables)
  @v02_index "kx_router_subscriptions_execution_id_binding_id_invoke_id_index"
  @v03_index "kx_router_subscriptions_invocation_index"

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)

    clear_leftovers()

    :ok = migrate(:up)
    on_exit(fn -> :ok = migrate(:down) end)

    {:ok, config} =
      Config.new(
        repo: TestRepo,
        delivery: StatifierRouter.RecordingDelivery,
        table_prefix: "kx_router_",
        prefix: @schema
      )

    {:ok, config: config}
  end

  # Clears what an earlier run left in the database, so the run after a red
  # or aborted one starts clean. Two leftover states need it, and each needs
  # a different half:
  #
  # - A `down/1` that completes but drops only part of the set (the sabotage
  #   on "runs down and up again cleanly" below is one) leaves the surviving
  #   tables in place, while `Ecto.Migrator.down/4` still deletes the
  #   `schema_migrations` row. The next `migrate(:up)` runs V01's CREATE
  #   TABLE against a table that is already there and raises 42P07
  #   duplicate_table in setup_all, so every test in the module is invalid.
  #   The DROP half clears this state; the DELETE half finds no row.
  # - A run that stops before its `on_exit` down (the VM killed mid-run)
  #   leaves every table and the version row. Deleting the row alone raises
  #   42P07 as above. Dropping the tables alone leaves the row with nothing
  #   under it, and `migrate/1` folds `:already_up` into `:ok`, so the next
  #   `migrate(:up)` creates nothing and every test fails on 42P01
  #   undefined_table. The DELETE half is what stops that.
  #
  # Hence both halves: every version's tables by their schema-qualified
  # names, and the `schema_migrations` row `migrate/1` reads. The migrator
  # is called with no `:prefix`, so that row is in the repo's default
  # schema rather than under @schema.
  defp clear_leftovers do
    # The location table first: it references the address table.
    for table <- @v04_tables ++ (@tables -- @v04_tables) do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{@schema}"."#{table}"), [])
    end

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
      [@version, @v01_version, @v02_version, @v03_version, @v04_version]
    ])

    :ok
  end

  defp migrate_step(direction, version, module) do
    case apply(Migrator, direction, [TestRepo, version, module, [log: false]]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  defp migrate(direction) do
    case apply(Migrator, direction, [TestRepo, @version, MigrateKx, [log: false]]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
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

  # Every index on the table, primary key included, so the assertion below is
  # a complete snapshot rather than a subset: an index V01 stops creating and
  # an index a later version adds both turn it red. Filtering on
  # `indisunique` here is what hid V01's three plain indexes from the suite.
  defp index_columns(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT i.relname, array_agg(a.attname ORDER BY k.ord)
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE n.nspname = $1 AND t.relname = $2
        GROUP BY i.relname
        """,
        [@schema, table]
      )

    Map.new(rows, fn [name, columns] -> {name, columns} end)
  end

  defp column_layout(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT column_name, collation_name
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        ORDER BY ordinal_position
        """,
        [@schema, table]
      )

    Enum.map(rows, fn [name, collation] -> {name, collation} end)
  end

  defp unique_suffix, do: Integer.to_string(System.unique_integer([:positive]))

  # sabotage: @version set back to 20_260_919_000_201 -> red on the
  # comparison, and the run printed Ecto's out-of-order warning again;
  # restored, green.
  test "every migration here sorts above every bootstrap migration" do
    ours = [@version, @v01_version, @v02_version, @v03_version, @v04_version]

    assert Enum.min(ours) > Enum.max(StatifierRouter.BootstrapMigrations.versions())
  end

  describe "every version through a host's delegating migration" do
    # sabotage: V01 named the ledger table "<prefix>ledger" -> red on the
    # table list; restored, green.
    test "creates every version's tables in the configured Postgres schema" do
      assert tables_present() == @tables
    end

    # sabotage: dropped V01's `create(index(addresses, [:execution_id], ...))`
    # -> red on the addresses index list, which the old indisunique filter had
    # hidden; restored, green. sabotage: removed V03 from the Migrations
    # version map -> red on the subscriptions index list, which kept V02's
    # name; restored, green.
    test "names every index on every version's tables and its columns" do
      assert index_columns("kx_router_addresses") == %{
               "kx_router_addresses_pkey" => ["id"],
               "kx_router_addresses_scope_document_key_index" => ["scope", "document", "key"],
               "kx_router_addresses_execution_id_index" => ["execution_id"]
             }

      assert index_columns("kx_router_dedupe") == %{
               "kx_router_dedupe_pkey" => ["id"],
               "kx_router_dedupe_binding_id_message_id_index" => ["binding_id", "message_id"],
               "kx_router_dedupe_expires_at_index" => ["expires_at"]
             }

      assert index_columns("kx_router_routing_ledger") == %{
               "kx_router_routing_ledger_pkey" => ["id"],
               "kx_router_routing_ledger_binding_id_inserted_at_index" => [
                 "binding_id",
                 "inserted_at"
               ]
             }

      assert index_columns("kx_router_subscriptions") == %{
               "kx_router_subscriptions_pkey" => ["id"],
               "kx_router_subscriptions_invocation_index" => [
                 "execution_id",
                 "binding_id",
                 "invoke_id"
               ]
             }

      assert index_columns("kx_router_locations") == %{
               "kx_router_locations_pkey" => ["id"],
               "kx_router_locations_address_id_index" => ["address_id"],
               "kx_router_locations_token_index" => ["token"]
             }
    end

    # With no layout option set, every table keeps the column order and the
    # default collations it had before the options existed.
    #
    # sabotage: made the :timestamps_position default in Migrations
    # :leading -> red on kx_router_addresses, inserted_at came back second;
    # restored, green.
    test "lays every table out in the package's order with no layout option" do
      assert column_layout("kx_router_addresses") == [
               {"id", nil},
               {"scope", nil},
               {"document", nil},
               {"key", nil},
               {"execution_id", nil},
               {"inserted_at", nil},
               {"terminal_seen_at", nil}
             ]

      assert column_layout("kx_router_dedupe") == [
               {"id", nil},
               {"binding_id", nil},
               {"message_id", nil},
               {"expires_at", nil}
             ]

      assert column_layout("kx_router_routing_ledger") == [
               {"id", nil},
               {"binding_id", nil},
               {"message_id", nil},
               {"scope", nil},
               {"outcome", nil},
               {"key", nil},
               {"execution_id", nil},
               {"reason", nil},
               {"inserted_at", nil}
             ]

      assert column_layout("kx_router_subscriptions") == [
               {"id", nil},
               {"binding_id", nil},
               {"execution_id", nil},
               {"invoke_id", nil},
               {"scope", nil},
               {"key", nil},
               {"inserted_at", nil}
             ]

      assert column_layout("kx_router_locations") == [
               {"id", nil},
               {"address_id", nil},
               {"token", nil},
               {"inserted_at", nil}
             ]
    end

    # sabotage: dropped V01's routing_ledger scope column -> the insert
    # raised (undefined column); restored, green.
    test "takes one row per table through the schemas", %{config: config} do
      suffix = unique_suffix()
      now = DateTime.utc_now()

      address =
        TestRepo.insert!(
          Config.put_meta(config, %Address{
            scope: "7c1e",
            document: "impression_click_join",
            key: "imp_" <> suffix,
            execution_id: "ex_" <> suffix
          })
        )

      assert %Address{terminal_seen_at: nil, inserted_at: %DateTime{}} =
               TestRepo.get!(Config.queryable(config, Address), address.id)

      dedupe =
        TestRepo.insert!(
          Config.put_meta(config, %Dedupe{
            binding_id: "impressions_to_join",
            message_id: "ad_events/3/" <> suffix,
            expires_at: DateTime.add(now, 72, :hour)
          })
        )

      assert %Dedupe{binding_id: "impressions_to_join"} =
               TestRepo.get!(Config.queryable(config, Dedupe), dedupe.id)

      ledger =
        TestRepo.insert!(
          Config.put_meta(config, %Ledger{
            binding_id: "clicks_to_join",
            message_id: "ad_events/5/" <> suffix,
            scope: "7c1e",
            outcome: "key_refused",
            reason: "{:key, {:value, :undefined}}"
          })
        )

      assert %Ledger{key: nil, execution_id: nil, outcome: "key_refused"} =
               TestRepo.get!(Config.queryable(config, Ledger), ledger.id)

      subscription =
        TestRepo.insert!(
          Config.put_meta(config, %Subscription{
            binding_id: "clicks_to_join",
            execution_id: "ex_" <> suffix,
            invoke_id: "inv_" <> suffix,
            scope: "7c1e",
            key: "imp_" <> suffix,
            inserted_at: now
          })
        )

      assert %Subscription{binding_id: "clicks_to_join", scope: "7c1e"} =
               TestRepo.get!(Config.queryable(config, Subscription), subscription.id)

      location =
        TestRepo.insert!(
          Config.put_meta(config, %Location{
            address_id: address.id,
            token: "tok_" <> suffix,
            inserted_at: now
          })
        )

      assert %Location{token: "tok_" <> ^suffix} =
               TestRepo.get!(Config.queryable(config, Location), location.id)
    end

    # sabotage: V04's address_id made a plain bigint with no reference ->
    # the location outlived its address row, red; restored, green.
    test "deletes an address row's location with it", %{config: config} do
      suffix = unique_suffix()

      address =
        TestRepo.insert!(
          Config.put_meta(config, %Address{
            scope: "7c1e",
            document: "parcel_route",
            key: "pcl_" <> suffix,
            execution_id: "ex_" <> suffix
          })
        )

      location =
        TestRepo.insert!(
          Config.put_meta(config, %Location{address_id: address.id, token: "tok_" <> suffix})
        )

      TestRepo.delete!(Config.put_meta(config, address))

      assert TestRepo.get(Config.queryable(config, Location), location.id) == nil
    end

    # sabotage: V04's token index made a plain index -> the second insert
    # succeeded, red; restored, green.
    test "refuses a second location with one token", %{config: config} do
      suffix = unique_suffix()

      [first, second] =
        for key <- ["pcl_a_" <> suffix, "pcl_b_" <> suffix] do
          TestRepo.insert!(
            Config.put_meta(config, %Address{
              scope: "7c1e",
              document: "parcel_route",
              key: key,
              execution_id: "ex_" <> key
            })
          )
        end

      TestRepo.insert!(
        Config.put_meta(config, %Location{address_id: first.id, token: "tok_" <> suffix})
      )

      error =
        assert_raise Ecto.ConstraintError, fn ->
          TestRepo.insert!(
            Config.put_meta(config, %Location{address_id: second.id, token: "tok_" <> suffix})
          )
        end

      assert error.constraint == "kx_router_locations_token_index"
    end

    # sabotage: V01's addresses unique index made a plain index -> the
    # second insert succeeded, red; restored, green.
    test "refuses a second address row for one (scope, document, key)", %{config: config} do
      row = %Address{
        scope: "7c1e",
        document: "impression_click_join",
        key: "imp_" <> unique_suffix(),
        execution_id: "ex_first"
      }

      TestRepo.insert!(Config.put_meta(config, row))

      error =
        assert_raise Ecto.ConstraintError, fn ->
          TestRepo.insert!(Config.put_meta(config, %{row | execution_id: "ex_second"}))
        end

      assert error.constraint == "kx_router_addresses_scope_document_key_index"

      # The same key under another scope is another address.
      assert %Address{} = TestRepo.insert!(Config.put_meta(config, %{row | scope: "91ab"}))
    end

    # sabotage: V01's dedupe unique index made a plain index -> the second
    # insert succeeded, red; restored, green.
    test "refuses a second dedupe row for one (binding_id, message_id)", %{config: config} do
      row = %Dedupe{
        binding_id: "clicks_to_join",
        message_id: "ad_events/3/" <> unique_suffix(),
        expires_at: DateTime.add(DateTime.utc_now(), 72, :hour)
      }

      TestRepo.insert!(Config.put_meta(config, row))

      error =
        assert_raise Ecto.ConstraintError, fn ->
          TestRepo.insert!(Config.put_meta(config, row))
        end

      assert error.constraint == "kx_router_dedupe_binding_id_message_id_index"
    end

    # sabotage: V02's subscriptions unique index made a plain index -> the
    # second insert succeeded, red; restored, green.
    test "refuses a second subscription row for one (execution, binding, invocation)", %{
      config: config
    } do
      suffix = unique_suffix()

      row = %Subscription{
        binding_id: "clicks_to_join",
        execution_id: "ex_" <> suffix,
        invoke_id: "inv_" <> suffix,
        scope: "7c1e",
        key: "imp_" <> suffix,
        inserted_at: DateTime.utc_now()
      }

      TestRepo.insert!(Config.put_meta(config, row))

      error =
        assert_raise Ecto.ConstraintError, fn ->
          TestRepo.insert!(Config.put_meta(config, row))
        end

      assert error.constraint == "kx_router_subscriptions_invocation_index"

      # A second invocation of the same binding in the same execution is a
      # second row, not a conflict (ADR-0007, section 6).
      assert %Subscription{} =
               TestRepo.insert!(Config.put_meta(config, %{row | invoke_id: "inv_b_" <> suffix}))
    end

    # This is the boundary a host upgrading across a version lands on, and
    # both ways of getting it wrong are silent: a `from:` read as exclusive
    # never runs V02 for them, and a `from:` that walks from V01 re-runs
    # V01's CREATE TABLE against tables they already have.
    #
    # sabotage: span!/3 made `from + 1` for :up -> the V02 step created no
    # subscriptions table, red on its assertion; restored, green.
    test "from: is inclusive, so a host on V01 reaches V02 with from: 2 and re-runs nothing" do
      :ok = migrate(:down)
      assert tables_present() == []

      :ok = migrate_step(:up, @v01_version, MigrateKxV01)
      assert tables_present() == @v01_tables

      # Inclusive of `from`: this call runs V02 itself, and only V02 - a
      # walk that included V01 would raise on the tables already there.
      :ok = migrate_step(:up, @v02_version, MigrateKxV02)
      assert tables_present() == Enum.sort(@v01_tables ++ @v02_tables)

      :ok = migrate_step(:up, @v03_version, MigrateKxV03)
      assert Map.has_key?(index_columns("kx_router_subscriptions"), @v03_index)
      assert tables_present() == @tables

      # V04 was walked already; running it again changes nothing.
      :ok = migrate_step(:up, @v04_version, MigrateKxV04)
      assert tables_present() == @tables

      # And back down the same way, one version at a time.
      :ok = migrate_step(:down, @v04_version, MigrateKxV04)
      assert tables_present() == Enum.sort(@v01_tables ++ @v02_tables)

      :ok = migrate_step(:down, @v03_version, MigrateKxV03)
      assert Map.has_key?(index_columns("kx_router_subscriptions"), @v02_index)

      :ok = migrate_step(:down, @v02_version, MigrateKxV02)
      assert tables_present() == @v01_tables

      :ok = migrate_step(:down, @v01_version, MigrateKxV01)
      assert tables_present() == []

      :ok = migrate(:up)
      assert tables_present() == @tables
    end

    # sabotage: V01's down/1 dropped only the ledger table -> red at
    # `assert tables_present() == []`, which still saw the other two;
    # restored, green.
    test "runs down and up again cleanly" do
      :ok = migrate(:down)
      assert tables_present() == []

      # down/1 leaves the Postgres schema itself in place.
      assert %{num_rows: 1} =
               SQL.query!(
                 TestRepo,
                 "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
                 [@schema]
               )

      :ok = migrate(:up)
      assert tables_present() == @tables
    end
  end

  describe "options" do
    # sabotage: parse! stopped rejecting unknown keys -> the call reached
    # the DDL and raised RuntimeError, red; restored, green.
    test "an unknown option raises before any DDL" do
      assert_raise ArgumentError, ~r/unknown_key, :repo/, fn -> Migrations.up(repo: TestRepo) end
    end

    # sabotage: Config.storage/1 accepted any table_prefix -> the call
    # reached the DDL and raised RuntimeError, red; restored, green.
    test "a table prefix that is not a non-empty string raises" do
      assert_raise ArgumentError, ~r/invalid_value, :table_prefix/, fn ->
        Migrations.down(table_prefix: "")
      end
    end

    # sabotage: validate_version! accepted any integer -> the call reached
    # the DDL and raised RuntimeError, red; restored, green.
    test "a version this package does not know raises" do
      assert_raise ArgumentError, ~r/unknown migration version 5/, fn ->
        Migrations.up(version: 5)
      end

      assert_raise ArgumentError, ~r/unknown migration from 0/, fn -> Migrations.down(from: 0) end
    end
  end
end
