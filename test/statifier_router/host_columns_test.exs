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

  # A leading column named like a package column that only a table outside
  # the call's span declares: invoke_id is the subscription table's alone
  # (V02), expires_at the dedupe table's alone (V01).
  defmodule MigrateHcV01Invoke do
    @moduledoc false
    use Ecto.Migration

    @opts [
      table_prefix: "hc_router_",
      prefix: "hc_router_schema",
      leading_columns: [invoke_id: {:text, null: true}]
    ]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [version: 1])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 1, version: 1])
  end

  defmodule MigrateHcV02Expires do
    @moduledoc false
    use Ecto.Migration

    @opts [
      table_prefix: "hc_router_",
      prefix: "hc_router_schema",
      leading_columns: [expires_at: {:utc_datetime_usec, null: true}]
    ]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 2])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 2, version: 2])
  end

  defmodule MigrateHcV02Plain do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: "hc_router_", prefix: "hc_router_schema"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 2])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 2, version: 2])
  end

  # A repo with its implicit primary key turned off leads with one of its
  # own named id: the package does not declare the primary key.
  defmodule MigrateHcOwnId do
    @moduledoc false
    use Ecto.Migration

    @opts [
      table_prefix: "hc_router_",
      prefix: "hc_router_schema",
      leading_columns: [id: {:bigserial, primary_key: true}]
    ]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  @version 20_260_925_000_301
  @v01_version 20_260_925_000_302
  @v02_version 20_260_925_000_303
  @v01_invoke_version 20_260_925_000_304
  @v02_expires_version 20_260_925_000_305
  @v02_plain_version 20_260_925_000_306
  @own_id_version 20_260_925_000_307
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
      [
        @version,
        @v01_version,
        @v02_version,
        @v01_invoke_version,
        @v02_expires_version,
        @v02_plain_version,
        @own_id_version
      ]
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

  describe "a leading column named like a package column" do
    # The refusal's column sets pinned to the DDL: every column the plain
    # migrations create but the repo's primary key, read back from the
    # catalog, is refused under the span that creates its table.
    # sabotage: dropped :terminal_seen_at from @package_columns' address
    # entry -> red here on terminal_seen_at, which then reached the DDL.
    test "is refused for every column the tables the call creates declare" do
      :ok = Migrator.up(TestRepo, @v01_version, MigrateHcV01Plain, log: false)
      :ok = Migrator.up(TestRepo, @v02_plain_version, MigrateHcV02Plain, log: false)

      for {table, span} <- [
            {"hc_router_addresses", [version: 1]},
            {"hc_router_dedupe", [version: 1]},
            {"hc_router_routing_ledger", [version: 1]},
            {"hc_router_subscriptions", [from: 2]}
          ],
          {column, _collation} <- columns(table),
          column != "id" do
        name = String.to_existing_atom(column)

        assert_raise ArgumentError,
                     ~r/names a column the package declares: #{inspect(name)} /,
                     fn ->
                       Migrations.up(span ++ [leading_columns: [{name, {:text, []}}]])
                     end
      end
    end

    # sabotage: made refuse_package_column_names!/2 check every version's
    # tables rather than the span's -> red here, invoke_id refused under
    # version: 1.
    test "is a host column when only a table outside the call declares it" do
      :ok = Migrator.up(TestRepo, @v01_invoke_version, MigrateHcV01Invoke, log: false)

      assert [{"id", nil}, {"invoke_id", nil}, {"scope", nil} | _] =
               columns("hc_router_addresses")

      :ok = Migrator.up(TestRepo, @v02_expires_version, MigrateHcV02Expires, log: false)

      assert [{"id", nil}, {"expires_at", nil}, {"binding_id", nil} | _] =
               columns("hc_router_subscriptions")

      :ok = Migrator.down(TestRepo, @v02_expires_version, MigrateHcV02Expires, log: false)
      :ok = Migrator.down(TestRepo, @v01_invoke_version, MigrateHcV01Invoke, log: false)
      assert tables_present() == []
    end

    # sabotage: put :id back in @package_columns' address entry -> red
    # here, the leading id was refused before the DDL.
    test "leads with a primary key of the host's own under migration_primary_key: false" do
      repo_env = Application.fetch_env!(:statifier_router, TestRepo)

      Application.put_env(
        :statifier_router,
        TestRepo,
        Keyword.put(repo_env, :migration_primary_key, false)
      )

      try do
        :ok = Migrator.up(TestRepo, @own_id_version, MigrateHcOwnId, log: false)
      after
        Application.put_env(:statifier_router, TestRepo, repo_env)
      end

      for table <- @tables do
        assert [{"id", nil} | _] = columns(table), table
      end

      :ok = Migrator.down(TestRepo, @own_id_version, MigrateHcOwnId, log: false)
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

    # One name per distinct set of tables that declares it under the
    # full walk: the three with a binding id, the three with a scope or
    # a timestamp, the address table alone, the dedupe table alone, the
    # ledger table alone and the subscription table alone; then the
    # address and ledger tables under version: 1. None of these reaches
    # the DDL, so the call needs no migration runner.
    # sabotage: made up/1 skip refuse_package_column_names!/2 -> red here,
    # the first name reached V01's DDL outside a migration runner.
    # sabotage: dropped :expires_at from @package_columns' dedupe entry ->
    # red here on :expires_at.
    test "reject a leading column a table the call creates already declares" do
      for {name, tables} <- [
            binding_id: "dedupe, routing_ledger, subscriptions",
            scope: "addresses, routing_ledger, subscriptions",
            document: "addresses",
            terminal_seen_at: "addresses",
            expires_at: "dedupe",
            reason: "routing_ledger",
            invoke_id: "subscriptions",
            inserted_at: "addresses, routing_ledger, subscriptions"
          ] do
        message =
          "the :leading_columns option names a column the package declares: " <>
            "#{inspect(name)} (in #{tables}); " <>
            "a host column needs a name no table this call creates declares"

        assert_raise ArgumentError, message, fn ->
          Migrations.up(leading_columns: [{:branch_id, {:text, []}}, {name, {:text, []}}])
        end
      end

      assert_raise ArgumentError, ~r/:inserted_at \(in addresses, routing_ledger\)/, fn ->
        Migrations.up(
          leading_columns: [inserted_at: {:text, []}],
          timestamps_position: :leading,
          version: 1
        )
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
