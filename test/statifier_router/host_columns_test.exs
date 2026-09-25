defmodule StatifierRouter.HostColumnsTest do
  # Live DDL outside the SQL sandbox, like migrations_test.exs: setup_all
  # switches the repo to :auto for the module and restores :manual on
  # exit, hence async: false, and :auto is repo-global, so the module is
  # tagged :isolated and runs in the gate's isolated stage.
  use ExUnit.Case, async: false

  @moduletag :isolated

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.Config
  alias StatifierRouter.Migrations
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger, Subscription}
  alias StatifierRouter.TestRepo

  # statifier_persistence's fixture shape: a leading text column of the
  # host's own, the timestamp moved to follow it, and a collation on the
  # execution id column.
  @layout [
    leading_columns: [branch_id: {:text, null: true}],
    timestamps_position: :leading,
    column_collations: [execution_id: "C"]
  ]

  defmodule MigrateHc do
    @moduledoc false
    use Ecto.Migration

    @opts [
      table_prefix: "hc_router_",
      prefix: "hc_router_schema",
      leading_columns: [branch_id: {:text, null: true}],
      timestamps_position: :leading,
      column_collations: [execution_id: "C"]
    ]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  # A host that built V01 before it set any layout option, then writes V02
  # with them: only the table V02 creates takes the layout.
  defmodule MigrateHcV01Plain do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "hc_router_", prefix: "hc_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [version: 1])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 1, version: 1])
  end

  defmodule MigrateHcV02Laid do
    @moduledoc false
    use Ecto.Migration

    @opts [
      table_prefix: "hc_router_",
      prefix: "hc_router_schema",
      leading_columns: [branch_id: {:text, null: true}],
      timestamps_position: :leading,
      column_collations: [execution_id: "C"]
    ]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 2])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 2, version: 2])
  end

  @version 20_260_925_000_301
  @v01_version 20_260_925_000_302
  @v02_version 20_260_925_000_303
  @schema "hc_router_schema"
  @tables [
    "hc_router_addresses",
    "hc_router_dedupe",
    "hc_router_routing_ledger",
    "hc_router_subscriptions"
  ]

  setup do
    Sandbox.mode(TestRepo, :auto)

    clear()

    on_exit(fn ->
      clear()
      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  defp clear do
    for table <- @tables do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{@schema}"."#{table}"), [])
    end

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
      [@version, @v01_version, @v02_version]
    ])

    :ok
  end

  # Every column of the table in ordinal order, with its collation (nil
  # for the database default and for a column that is not text), read
  # back from the catalog rather than from the migration.
  defp columns(table) do
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

  @laid_out %{
    "hc_router_addresses" => [
      {"id", nil},
      {"branch_id", nil},
      {"inserted_at", nil},
      {"scope", nil},
      {"document", nil},
      {"key", nil},
      {"execution_id", "C"},
      {"terminal_seen_at", nil}
    ],
    "hc_router_dedupe" => [
      {"id", nil},
      {"branch_id", nil},
      {"binding_id", nil},
      {"message_id", nil},
      {"expires_at", nil}
    ],
    "hc_router_routing_ledger" => [
      {"id", nil},
      {"branch_id", nil},
      {"inserted_at", nil},
      {"binding_id", nil},
      {"message_id", nil},
      {"scope", nil},
      {"outcome", nil},
      {"key", nil},
      {"execution_id", "C"},
      {"reason", nil}
    ],
    "hc_router_subscriptions" => [
      {"id", nil},
      {"branch_id", nil},
      {"inserted_at", nil},
      {"binding_id", nil},
      {"execution_id", "C"},
      {"invoke_id", nil},
      {"scope", nil},
      {"key", nil}
    ]
  }

  describe "the layout options" do
    # sabotage: dropped add_leading_columns(storage) from V01's dedupe
    # block -> red on hc_router_dedupe, which came back without branch_id.
    # sabotage: made V02's add_inserted_at/2 ignore :leading (always
    # trailing) -> red on hc_router_subscriptions, inserted_at came back
    # last. sabotage: made V01's collated/3 return opts unchanged -> red on
    # hc_router_addresses, execution_id came back with no collation.
    test "place a leading column, the timestamp and a collation on all four tables" do
      :ok = Migrator.up(TestRepo, @version, MigrateHc, log: false)

      for table <- @tables do
        assert columns(table) == Map.fetch!(@laid_out, table), table
      end
    end

    # sabotage: V01's add_leading_columns/1 forced null: false on every
    # column -> red here, the address insert raised not_null_violation on
    # branch_id.
    test "the package's own writes leave the host's column alone" do
      :ok = Migrator.up(TestRepo, @version, MigrateHc, log: false)

      {:ok, config} =
        Config.new(
          repo: TestRepo,
          delivery: StatifierRouter.RecordingDelivery,
          table_prefix: "hc_router_",
          prefix: @schema
        )

      now = DateTime.utc_now()

      rows = [
        %Address{scope: "7c1e", document: "loan", key: "copy_17", execution_id: "ex_hc1"},
        %Dedupe{
          binding_id: "loan_events",
          message_id: "loans/1",
          expires_at: DateTime.add(now, 1, :hour)
        },
        %Ledger{
          binding_id: "loan_events",
          message_id: "loans/1",
          scope: "7c1e",
          outcome: "delivered"
        },
        %Subscription{
          binding_id: "loan_events",
          execution_id: "ex_hc1",
          invoke_id: "inv_loan_1",
          scope: "7c1e",
          key: "copy_17",
          inserted_at: now
        }
      ]

      for {row, table} <- Enum.zip(rows, @tables) do
        inserted = TestRepo.insert!(Config.put_meta(config, row))

        assert %{rows: [[nil]]} =
                 SQL.query!(
                   TestRepo,
                   ~s(SELECT branch_id FROM "#{@schema}"."#{table}" WHERE id = $1),
                   [inserted.id]
                 )
      end
    end

    # sabotage: made V02.up/1 read the layout off a hardcoded empty map ->
    # red on hc_router_subscriptions, which came back in the plain layout.
    test "place a column only in the table the version creates" do
      :ok = Migrator.up(TestRepo, @v01_version, MigrateHcV01Plain, log: false)
      :ok = Migrator.up(TestRepo, @v02_version, MigrateHcV02Laid, log: false)

      assert columns("hc_router_addresses") == [
               {"id", nil},
               {"scope", nil},
               {"document", nil},
               {"key", nil},
               {"execution_id", nil},
               {"inserted_at", nil},
               {"terminal_seen_at", nil}
             ]

      assert columns("hc_router_subscriptions") ==
               Map.fetch!(@laid_out, "hc_router_subscriptions")

      :ok = Migrator.down(TestRepo, @v02_version, MigrateHcV02Laid, log: false)
      :ok = Migrator.down(TestRepo, @v01_version, MigrateHcV01Plain, log: false)
      assert tables_present() == []
    end

    # The same options list serves down/1, which accepts and ignores it.
    test "roll back to no table at all" do
      :ok = Migrator.up(TestRepo, @version, MigrateHc, log: false)
      assert tables_present() == @tables

      :ok = Migrator.down(TestRepo, @version, MigrateHc, log: false)
      assert tables_present() == []
    end
  end

  describe "the options" do
    # sabotage: made layout!/1 take :leading_columns unchecked -> red
    # here, the first malformed spelling reached the DDL.
    test "reject a malformed :leading_columns before any DDL" do
      for bad <- [
            :branch_id,
            [{"branch_id", {:text, []}}],
            [branch_id: :text],
            [branch_id: {:text, [:null]}],
            [branch_id: {:text, []}, branch_id: {:bigint, []}]
          ] do
        assert_raise ArgumentError, ~r/:leading_columns/, fn ->
          Migrations.up(leading_columns: bad)
        end
      end
    end

    # sabotage: made layout!/1 take :timestamps_position unchecked -> red
    # here, :first reached the DDL.
    test "reject a :timestamps_position other than :trailing or :leading" do
      assert_raise ArgumentError, ~r/:timestamps_position option must be one of/, fn ->
        Migrations.up(timestamps_position: :first)
      end
    end

    # sabotage: made layout!/1 take :column_collations unchecked -> red
    # here, the first malformed spelling reached the DDL.
    test "reject a malformed :column_collations and an unknown column" do
      for bad <- [
            "C",
            [execution_id: ""],
            [execution_id: :c],
            [execution_id: "C", execution_id: "POSIX"]
          ] do
        assert_raise ArgumentError, ~r/:column_collations/, fn ->
          Migrations.up(column_collations: bad)
        end
      end

      assert_raise ArgumentError, ~r/unknown column :branch_id in :column_collations/, fn ->
        Migrations.up(column_collations: [branch_id: "C"])
      end
    end

    # The three are options of the migration, never keys of the
    # configuration a host routes with.
    test "are not StatifierRouter.Config keys" do
      for {name, value} <- @layout do
        assert {:error, {:unknown_key, ^name}} =
                 Config.new([
                   {:repo, TestRepo},
                   {:delivery, StatifierRouter.RecordingDelivery},
                   {name, value}
                 ])
      end
    end
  end
end
