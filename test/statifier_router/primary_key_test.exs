defmodule StatifierRouter.PrimaryKeyTest do
  # Live DDL and live deliveries outside the SQL sandbox, like
  # host_columns_test.exs: setup switches the repo to :auto and restores
  # :manual on exit, hence async: false, and :auto is repo-global, so the
  # module is tagged :isolated and runs in the gate's isolated stage. The
  # deliveries commit, so every execution they create is deleted again.
  use ExUnit.Case, async: false

  @moduletag :isolated

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.Addresses
  alias StatifierRouter.Config
  alias StatifierRouter.Migrations
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger, Subscription}
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @schema "pk_router_schema"
  @table_prefix "pk_router_"
  @sequence ~s("pk_router_schema"."pk_router_ids")
  @now ~U[2026-09-26 08:00:00.000000Z]

  # Every version, under a table prefix and a Postgres schema of its own,
  # with no primary key option: the tables a host builds today.
  defmodule MigratePlain do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "pk_router_", prefix: "pk_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  # The same, with a sortable text id the database fills in from a
  # sequence the test creates: "r000000000001", "r000000000002", ...
  defmodule MigrateText do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(opts())
    def down, do: StatifierRouter.Migrations.down(opts())

    defp opts do
      [
        table_prefix: "pk_router_",
        prefix: "pk_router_schema",
        primary_key: [
          type: :text,
          default:
            fragment(
              ~s|'r' \|\| lpad(nextval('"pk_router_schema"."pk_router_ids"')::text, 12, '0')|
            )
        ]
      ]
    end
  end

  # A text id made of digits alone: "000000000001", ... The package binds
  # such an id as the table hands it back, so it never becomes an integer.
  defmodule MigrateDigits do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(opts())
    def down, do: StatifierRouter.Migrations.down(opts())

    defp opts do
      [
        table_prefix: "pk_router_",
        prefix: "pk_router_schema",
        primary_key: [
          type: :text,
          default:
            fragment(~s|lpad(nextval('"pk_router_schema"."pk_router_ids"')::text, 12, '0')|)
        ]
      ]
    end
  end

  @plain_version 20_260_926_000_401
  @text_version 20_260_926_000_402
  @digits_version 20_260_926_000_403
  @versions [@plain_version, @text_version, @digits_version]
  @tables [
    "pk_router_addresses",
    "pk_router_dedupe",
    "pk_router_routing_ledger",
    "pk_router_subscriptions"
  ]

  # The DDL every version logged for MigratePlain on main before the
  # primary key option existed (statifier_router at d426c1c), statement by
  # statement. A host that sets no primary key option runs exactly this.
  @plain_ddl [
    ~s|CREATE SCHEMA IF NOT EXISTS "pk_router_schema"|,
    ~s|CREATE TABLE "pk_router_schema"."pk_router_addresses" ("id" bigserial, "scope" text NOT NULL, "document" text NOT NULL, "key" text NOT NULL, "execution_id" text NOT NULL, "inserted_at" timestamp NOT NULL, "terminal_seen_at" timestamp NULL, PRIMARY KEY ("id"))|,
    ~s|CREATE UNIQUE INDEX "pk_router_addresses_scope_document_key_index" ON "pk_router_schema"."pk_router_addresses" ("scope", "document", "key")|,
    ~s|CREATE INDEX "pk_router_addresses_execution_id_index" ON "pk_router_schema"."pk_router_addresses" ("execution_id")|,
    ~s|CREATE TABLE "pk_router_schema"."pk_router_dedupe" ("id" bigserial, "binding_id" text NOT NULL, "message_id" text NOT NULL, "expires_at" timestamp NOT NULL, PRIMARY KEY ("id"))|,
    ~s|CREATE UNIQUE INDEX "pk_router_dedupe_binding_id_message_id_index" ON "pk_router_schema"."pk_router_dedupe" ("binding_id", "message_id")|,
    ~s|CREATE INDEX "pk_router_dedupe_expires_at_index" ON "pk_router_schema"."pk_router_dedupe" ("expires_at")|,
    ~s|CREATE TABLE "pk_router_schema"."pk_router_routing_ledger" ("id" bigserial, "binding_id" text NOT NULL, "message_id" text NOT NULL, "scope" text NOT NULL, "outcome" text NOT NULL, "key" text NULL, "execution_id" text NULL, "reason" text NULL, "inserted_at" timestamp NOT NULL, PRIMARY KEY ("id"))|,
    ~s|CREATE INDEX "pk_router_routing_ledger_binding_id_inserted_at_index" ON "pk_router_schema"."pk_router_routing_ledger" ("binding_id", "inserted_at")|,
    ~s|CREATE SCHEMA IF NOT EXISTS "pk_router_schema"|,
    ~s|CREATE TABLE "pk_router_schema"."pk_router_subscriptions" ("id" bigserial, "binding_id" text NOT NULL, "execution_id" text NOT NULL, "invoke_id" text NOT NULL, "scope" text NOT NULL, "key" text NOT NULL, "inserted_at" timestamp NOT NULL, PRIMARY KEY ("id"))|,
    ~s|CREATE UNIQUE INDEX "pk_router_subscriptions_execution_id_binding_id_invoke_id_index" ON "pk_router_schema"."pk_router_subscriptions" ("execution_id", "binding_id", "invoke_id")|,
    ~s|ALTER INDEX IF EXISTS "pk_router_schema"."pk_router_subscriptions_execution_id_binding_id_invoke_id_index" RENAME TO "pk_router_subscriptions_invocation_index"|
  ]

  setup do
    Sandbox.mode(TestRepo, :auto)

    clear()
    SQL.query!(TestRepo, ~s(CREATE SCHEMA IF NOT EXISTS "#{@schema}"), [])
    SQL.query!(TestRepo, "CREATE SEQUENCE #{@sequence}", [])

    on_exit(fn ->
      clear()
      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  # The executions a test's deliveries created, found through its routing
  # ledger before the tables go, then the tables, the sequence and the
  # migration versions.
  defp clear do
    %{rows: [[ledger]]} =
      SQL.query!(TestRepo, "SELECT to_regclass($1)::text", [
        ~s("#{@schema}"."pk_router_routing_ledger")
      ])

    if ledger do
      %{rows: rows} =
        SQL.query!(
          TestRepo,
          ~s(SELECT DISTINCT execution_id FROM "#{@schema}"."pk_router_routing_ledger" ) <>
            "WHERE execution_id IS NOT NULL",
          []
        )

      ids = List.flatten(rows)
      TestRepo.delete_all(from(i in TestPersistence.Input, where: i.execution_id in ^ids))
      TestRepo.delete_all(from(e in TestPersistence.Execution, where: e.execution_id in ^ids))
    end

    for table <- @tables do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{@schema}"."#{table}"), [])
    end

    SQL.query!(TestRepo, "DROP SEQUENCE IF EXISTS #{@sequence}", [])

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [@versions])

    :ok
  end

  # The statements a migration sent, in order, read from the log Ecto
  # writes when it is asked to log the migration's SQL.
  defp ddl(version, module) do
    log =
      capture_log(fn ->
        :ok = Migrator.up(TestRepo, version, module, log: false, log_migrations_sql: :error)
      end)

    ~r/^((?:CREATE|ALTER) .*?) \[\]$/m
    |> Regex.scan(log, capture: :all_but_first)
    |> List.flatten()
  end

  defp routing_config do
    config(self(),
      bindings: parcel_bindings(),
      table_prefix: @table_prefix,
      prefix: @schema
    )
  end

  defp scan(message_id, kind, parcel_id) do
    %{parcel_scan(message_id, kind) | data: %{"kind" => kind, "parcel_id" => parcel_id}}
  end

  describe "the option left out" do
    # sabotage: made V01's table_opts/1 hand table/2 primary_key: [name:
    # :id, type: :bigint] when the option is nil -> V01's CREATE TABLEs
    # came back with "id" bigint, red; restored, green.
    test "every version sends exactly the DDL it sent before the option existed" do
      assert ddl(@plain_version, MigratePlain) == @plain_ddl
    end
  end

  describe "a text primary key" do
    # sabotage: made V02's table_opts/1 ignore the option -> the
    # subscription table came back "id" bigserial, red; restored, green.
    test "changes only the id column of every table a version creates" do
      default =
        ~s|DEFAULT 'r' \|\| lpad(nextval('"pk_router_schema"."pk_router_ids"')::text, 12, '0')|

      expected =
        Enum.map(@plain_ddl, &String.replace(&1, ~s("id" bigserial), ~s("id" text #{default})))

      assert ddl(@text_version, MigrateText) == expected

      for table <- @tables do
        assert %{rows: [["text"]]} =
                 SQL.query!(
                   TestRepo,
                   "SELECT data_type FROM information_schema.columns " <>
                     "WHERE table_schema = $1 AND table_name = $2 AND column_name = 'id'",
                   [@schema, table]
                 ),
               table
      end
    end

    # sabotage: dropped StatifierRouter.Schema.Address's @primary_key, so
    # it took Ecto's default :id type back -> reading the address rows
    # raised loading a text id, red; restored, green. Second mutation:
    # examine/3's :after clause made always true -> the second page
    # re-read the first page's rows, red; restored, green.
    test "takes a delivery and a sweep, and a row through every schema" do
      :ok = Migrator.up(TestRepo, @text_version, MigrateText, log: false)
      config = routing_config()

      # A parcel scanned onto the van and then to the doorstep finishes
      # its execution; a second doorstep scan finds it finished and stamps
      # its address row in the delivery.
      {:ok, [{:created_and_delivered, "loaded_scans", done}, {:no_match, _}]} =
        StatifierRouter.route(config, scan("depot/1/1", "loaded", "pcl_5001"), now: @now)

      {:ok, [{:no_match, _}, {:delivered, "delivered_scans", ^done}]} =
        StatifierRouter.route(config, scan("depot/1/2", "delivered", "pcl_5001"), now: @now)

      assert {:ok, [{:no_match, _}, {:dropped, "delivered_scans", :finished}]} =
               StatifierRouter.route(config, scan("depot/1/3", "delivered", "pcl_5001"),
                 now: @now
               )

      # Two more parcels, still on the van.
      for {message_id, parcel_id} <- [{"depot/1/4", "pcl_5002"}, {"depot/1/5", "pcl_5003"}] do
        {:ok, [{:created_and_delivered, _, _}, _]} =
          StatifierRouter.route(config, scan(message_id, "loaded", parcel_id), now: @now)
      end

      # One sequence feeds every table, so the ids are sortable and
      # distinct but not consecutive within a table.
      assert [
               %Address{id: "r" <> _, key: "pcl_5001", terminal_seen_at: @now},
               %Address{id: "r" <> _ = second, key: "pcl_5002", terminal_seen_at: nil},
               %Address{id: "r" <> _, key: "pcl_5003", terminal_seen_at: nil}
             ] = TestRepo.all(from(a in Config.queryable(config, Address), order_by: a.id))

      assert %Address{key: "pcl_5001"} = Addresses.by_execution(config, done)

      assert Enum.all?(ledger(config), &(is_binary(&1.id) and &1.id =~ ~r/^r\d{12}$/))
      assert [_ | _] = dedupe = TestRepo.all(Config.queryable(config, Dedupe))
      assert Enum.all?(dedupe, &is_binary(&1.id))

      # The sweep, two rows a page, under bindings that give the parcel
      # document a horizon of zero: the finished parcel's row goes.
      assert Addresses.reap(config, [], now: @now, limit: 2) ==
               {:ok, %{stamped: 0, deleted: 1, next: second}}

      assert Addresses.reap(config, [], now: @now, limit: 2, after: second) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert ["pcl_5002", "pcl_5003"] =
               TestRepo.all(
                 from(a in Config.queryable(config, Address), order_by: a.id, select: a.key)
               )

      # The subscription table, through its schema, looked up by its id
      # with a where clause that binds it uncast, as a host on a text key
      # does: a text id is never cast.
      subscription =
        TestRepo.insert!(
          Config.put_meta(config, %Subscription{
            binding_id: "loaded_scans",
            execution_id: done,
            invoke_id: "inv_1",
            scope: "7c1e",
            key: "pcl_5001",
            inserted_at: @now
          })
        )

      assert "r" <> _ = subscription.id

      assert %Subscription{invoke_id: "inv_1"} =
               TestRepo.one!(
                 from(r in Config.queryable(config, Subscription),
                   where: fragment("? = ?", r.id, ^subscription.id)
                 )
               )

      ledger_id = hd(ledger(config)).id

      assert %Ledger{id: ^ledger_id} =
               TestRepo.one!(
                 from(r in Config.queryable(config, Ledger),
                   where: fragment("? = ?", r.id, ^ledger_id)
                 )
               )
    end

    # sabotage: bound delete/2's ids with `a.id in ^ids` again -> the
    # digit-only id cast to an integer and the reap raised encoding it
    # for the text column, red; restored, green. Second mutation: bound
    # the delivery's stamp with `a.id == ^id` -> the finished-scan
    # delivery raised the same way, red; restored, green.
    test "never casts a text id made of digits alone" do
      :ok = Migrator.up(TestRepo, @digits_version, MigrateDigits, log: false)
      config = routing_config()

      {:ok, [{:created_and_delivered, _, done}, _]} =
        StatifierRouter.route(config, scan("depot/2/1", "loaded", "pcl_6001"), now: @now)

      {:ok, [_, {:delivered, _, ^done}]} =
        StatifierRouter.route(config, scan("depot/2/2", "delivered", "pcl_6001"), now: @now)

      {:ok, [{:created_and_delivered, _, _}, _]} =
        StatifierRouter.route(config, scan("depot/2/3", "loaded", "pcl_6002"), now: @now)

      assert {:ok, [_, {:dropped, _, :finished}]} =
               StatifierRouter.route(config, scan("depot/2/4", "delivered", "pcl_6001"),
                 now: @now
               )

      assert [
               %Address{id: first, key: "pcl_6001", terminal_seen_at: @now},
               %Address{id: second, key: "pcl_6002", terminal_seen_at: nil}
             ] = TestRepo.all(from(a in Config.queryable(config, Address), order_by: a.id))

      assert first =~ ~r/^\d{12}$/
      assert second =~ ~r/^\d{12}$/

      # Stamped and still inside a one-hour horizon: kept at the first
      # reap, deleted at the second, the cursor a digit string throughout.
      bindings = for b <- config.bindings, do: %{b | dedupe: %{b.dedupe | horizon_ms: 3_600_000}}

      assert Addresses.reap(config, bindings, now: @now, limit: 1) ==
               {:ok, %{stamped: 0, deleted: 0, next: first}}

      assert Addresses.reap(config, [], now: @now, limit: 1) ==
               {:ok, %{stamped: 0, deleted: 1, next: first}}

      assert Addresses.reap(config, [], now: @now, after: first) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert [%Address{id: ^second}] = TestRepo.all(Config.queryable(config, Address))
    end

    # sabotage: examine/3 dropped its rescue -> the integer cursor raised
    # DBConnection.EncodeError, red; restored, green.
    test "refuses a cursor the id column cannot hold" do
      :ok = Migrator.up(TestRepo, @text_version, MigrateText, log: false)
      config = routing_config()

      assert Addresses.reap(config, [], after: 5) == {:error, {:invalid_value, :after, 5}}
    end
  end

  describe "StatifierRouter.Schema.Id" do
    alias StatifierRouter.Schema.Id

    # sabotage: made cast/1 pass a string that spells no integer
    # through -> "r000000000001" cast to itself, red; restored, green.
    # Second mutation: made cast/1 pass every string through -> "42"
    # stayed a string, red; restored, green.
    test "casts exactly as Ecto's :id does" do
      for value <- [42, "42", "r000000000001", "", 4.2, nil] do
        assert Id.cast(value) == Ecto.Type.cast(:id, value), inspect(value)
      end

      assert Id.cast("42") == {:ok, 42}
      assert Id.cast("r000000000001") == :error
    end

    # sabotage: made load/1 accept integers only -> the text id was
    # refused, red; restored, green.
    test "loads and dumps an integer or a string unchanged" do
      for id <- [42, "000000000042", "r000000000001"] do
        assert Id.load(id) == {:ok, id}
        assert Id.dump(id) == {:ok, id}
      end

      assert Id.load(4.2) == :error
      assert Id.dump(4.2) == :error
      assert Id.type() == :id
    end
  end

  describe "the option's validation" do
    # sabotage: validate_primary_key!/1 stopped refusing an unknown key ->
    # [type: :text, name: :key] passed validation, red; restored, green.
    test "a malformed primary key option raises before any DDL" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Migrations.up(primary_key: :text)
      end

      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Migrations.up(primary_key: [])
      end

      assert_raise ArgumentError, ~r/takes only :type and :default, got: \[:name\]/, fn ->
        Migrations.up(primary_key: [type: :text, name: :key])
      end

      assert_raise ArgumentError, ~r/needs a :type/, fn ->
        Migrations.up(primary_key: [default: "x"])
      end

      assert_raise ArgumentError, ~r/more than once/, fn ->
        Migrations.up(primary_key: [type: :text, type: :uuid])
      end
    end

    # sabotage: refuse_package_column_names!/3 ignored the primary key
    # option -> the leading id reached the DDL, red; restored, green.
    test "a leading id is refused once the package declares the key" do
      assert_raise ArgumentError,
                   ~r/names a column the package declares: :id \(in addresses, dedupe, routing_ledger\)/,
                   fn ->
                     Migrations.up(
                       version: 1,
                       primary_key: [type: :text],
                       leading_columns: [id: {:bigserial, primary_key: true}]
                     )
                   end
    end
  end
end
