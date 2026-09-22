defmodule StatifierRouter.MigrationsTest do
  # Live migration tests manage their own DDL and rows outside the SQL
  # sandbox: setup_all switches the repo to :auto for the module and
  # restores :manual on exit, hence async: false.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.Config
  alias StatifierRouter.Migrations
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger}
  alias StatifierRouter.TestRepo

  # A host's one-line delegating migration, under a table prefix and a
  # Postgres schema of its own, so these tests never touch the tables the
  # bootstrap created for the rest of the suite.
  defmodule MigrateKx do
    use Ecto.Migration

    @opts [table_prefix: "kx_router_", prefix: "kx_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  @version 20_260_919_000_201
  @schema "kx_router_schema"
  @tables ["kx_router_addresses", "kx_router_dedupe", "kx_router_routing_ledger"]

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

  # A run that goes red between the DDL and `on_exit` strands the kx tables:
  # the down that would have removed them either never runs or removes only
  # part of the set. `migrate/1` cannot recover from that on its own, because
  # it folds `:already_up` into `:ok` - the version row outlives the tables,
  # so the next `migrate(:up)` reports success and creates nothing, and every
  # test then fails on a missing relation. Clearing both halves is what makes
  # the run after a red one start clean: the three tables by their
  # schema-qualified names, and the `schema_migrations` row `migrate/1` reads.
  # The migrator is called with no `:prefix`, so that row is in the repo's
  # default schema rather than under @schema.
  defp clear_leftovers do
    for table <- @tables do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{@schema}"."#{table}"), [])
    end

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = $1", [@version])

    :ok
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

  defp unique_suffix, do: Integer.to_string(System.unique_integer([:positive]))

  describe "V01 through a host's delegating migration" do
    # sabotage: V01 named the ledger table "<prefix>ledger" -> red on the
    # table list; restored, green.
    test "creates the three tables in the configured Postgres schema" do
      assert tables_present() == @tables
    end

    # sabotage: dropped V01's `create(index(addresses, [:execution_id], ...))`
    # -> red on the addresses index list, which the old indisunique filter had
    # hidden; restored, green.
    test "names every index on the three tables and its columns" do
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
      assert_raise ArgumentError, ~r/unknown migration version 2/, fn ->
        Migrations.up(version: 2)
      end

      assert_raise ArgumentError, ~r/unknown migration from 0/, fn -> Migrations.down(from: 0) end
    end
  end
end
