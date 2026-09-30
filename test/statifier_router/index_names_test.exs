defmodule StatifierRouter.IndexNamesTest do
  # The index names the versions build under the DEFAULT table prefix, in a
  # Postgres schema of this module's own, so the suite's bootstrap tables in
  # the default schema are never touched. Like StatifierRouter.MigrationsTest
  # it runs DDL outside the SQL sandbox: setup_all switches the repo to
  # :auto, hence async: false and the :isolated tag (test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :isolated

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierRouter.TestRepo

  @schema "router_index_names"

  # A host at the default table prefix: its migration for V01 and V02,
  # written before V03 existed, and the one it adds for V03.
  defmodule MigrateThroughV02 do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(prefix: "router_index_names", version: 2)
    def down, do: StatifierRouter.Migrations.down(prefix: "router_index_names", from: 2)
  end

  defmodule MigrateV03 do
    @moduledoc false
    use Ecto.Migration

    @opts [prefix: "router_index_names"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 3])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 3, version: 3])
  end

  # The same V03 call under a second migration version: what a host's
  # database runs when an uncapped first migration already walked through
  # V03 on a fresh database.
  defmodule MigrateV03Again do
    @moduledoc false
    use Ecto.Migration

    @opts [prefix: "router_index_names"]

    def up, do: StatifierRouter.Migrations.up(@opts ++ [from: 3])
    def down, do: StatifierRouter.Migrations.down(@opts ++ [from: 3, version: 3])
  end

  defmodule MigrateAll do
    @moduledoc false
    use Ecto.Migration

    def up, do: StatifierRouter.Migrations.up(prefix: "router_index_names")
    def down, do: StatifierRouter.Migrations.down(prefix: "router_index_names")
  end

  # The longest :table_prefix every version accepts, and one byte more
  # (StatifierRouter.Migrations, "Index names and a long :table_prefix").
  @long_prefix String.duplicate("x", 47) <> "_"
  @too_long_prefix String.duplicate("x", 48) <> "_"

  defmodule MigrateLong do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: String.duplicate("x", 47) <> "_", prefix: "router_index_names"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  defmodule MigrateTooLong do
    @moduledoc false
    use Ecto.Migration

    @opts [table_prefix: String.duplicate("x", 48) <> "_", prefix: "router_index_names"]

    def up, do: StatifierRouter.Migrations.up(@opts)
    def down, do: StatifierRouter.Migrations.down(@opts)
  end

  @through_v02_version 20_260_926_000_301
  @v03_version 20_260_926_000_302
  @v03_again_version 20_260_926_000_303
  @all_version 20_260_926_000_304
  @long_version 20_260_926_000_305
  @too_long_version 20_260_926_000_306

  @subscriptions "statifier_router_subscriptions"
  @v02_spelling "statifier_router_subscriptions_execution_id_binding_id_invoke_id_index"
  @v03_name "statifier_router_subscriptions_invocation_index"

  # Postgres's NAMEDATALEN - 1.
  @max_identifier_bytes 63

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
    :ok
  end

  # Every test starts from an empty schema and leaves one: the schema is
  # this module's alone, so dropping it whole is safe, and the version rows
  # the migrator wrote go with it.
  setup do
    clear()
    on_exit(&clear/0)
    :ok
  end

  defp clear do
    SQL.query!(TestRepo, ~s(DROP SCHEMA IF EXISTS "#{@schema}" CASCADE), [])

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
      [
        @through_v02_version,
        @v03_version,
        @v03_again_version,
        @all_version,
        @long_version,
        @too_long_version
      ]
    ])

    :ok
  end

  defp migrate(direction, version, module, opts \\ []) do
    case apply(Migrator, direction, [TestRepo, version, module, [log: false] ++ opts]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  # name => {unique?, columns in index order}, for every index on the table.
  defp indexes(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT i.relname, x.indisunique, array_agg(a.attname ORDER BY k.ord)
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE n.nspname = $1 AND t.relname = $2
        GROUP BY i.relname, x.indisunique
        """,
        [@schema, table]
      )

    Map.new(rows, fn [name, unique, columns] -> {name, {unique, columns}} end)
  end

  defp index_names_in_schema do
    %{rows: rows} =
      SQL.query!(TestRepo, "SELECT indexname FROM pg_indexes WHERE schemaname = $1", [@schema])

    List.flatten(rows)
  end

  describe "the subscription index under the default table prefix" do
    # sabotage: made V03 rename from V02's spelling with `execution_id`
    # written `execution_idx` -> up/1 renamed nothing (IF EXISTS found no
    # such index) and the index kept V02's truncated name, red; restored,
    # green.
    test "V02 left it under a truncated name, and V03 renames that index" do
      :ok = migrate(:up, @through_v02_version, MigrateThroughV02)

      # What Postgres made of V02's 70-byte spelling: its first 63 bytes.
      truncated = binary_part(@v02_spelling, 0, @max_identifier_bytes)
      assert byte_size(@v02_spelling) == 70
      assert truncated == "statifier_router_subscriptions_execution_id_binding_id_invoke_i"

      assert %{^truncated => {true, ["execution_id", "binding_id", "invoke_id"]}} =
               indexes(@subscriptions)

      :ok = migrate(:up, @v03_version, MigrateV03)

      assert indexes(@subscriptions) == %{
               "statifier_router_subscriptions_pkey" => {true, ["id"]},
               @v03_name => {true, ["execution_id", "binding_id", "invoke_id"]}
             }

      # A second run finds the index already renamed and does nothing.
      :ok = migrate(:up, @v03_again_version, MigrateV03Again)
      assert Map.has_key?(indexes(@subscriptions), @v03_name)
      :ok = migrate(:down, @v03_again_version, MigrateV03Again)

      # down/1 puts back the name V02 left, so V02's own down/1 and any
      # host reading the old name see the database as it was.
      refute Map.has_key?(indexes(@subscriptions), @v03_name)
      assert %{^truncated => {true, _columns}} = indexes(@subscriptions)

      :ok = migrate(:down, @v03_version, MigrateV03)
      :ok = migrate(:down, @through_v02_version, MigrateThroughV02)
      assert index_names_in_schema() == []
    end
  end

  describe "every index name the versions build" do
    # The names as each version spells them in its DDL, read off the SQL the
    # migrator logs, because Postgres truncates a long name silently apart
    # from a notice, and the catalog alone cannot tell a truncated name
    # from one that fit.
    #
    # sabotage: named V03's index
    # "<table>_execution_id_binding_id_invoke_id_unique_index" -> red, the
    # over-length list gained it; restored, green.
    test "fits in 63 bytes at the default prefix, but V02's, which V03 renames" do
      log =
        capture_log(fn ->
          # :error, because config/test.exs keeps the logger at :warning.
          :ok = migrate(:up, @all_version, MigrateAll, log_migrations_sql: :error)
        end)

      built =
        Regex.scan(~r/(?:CREATE (?:UNIQUE )?INDEX|RENAME TO) "([^"]+)"/, log,
          capture: :all_but_first
        )
        |> List.flatten()

      # Every create and the rename were seen: V01's five indexes, V02's one
      # and V03's new name.
      assert length(built) == 7

      assert Enum.filter(built, &(byte_size(&1) > @max_identifier_bytes)) == [@v02_spelling]

      # What the tables end with: each name one a version spelled in full
      # (a truncated name is spelled by none), within 63 bytes. Primary
      # keys are named by Postgres, not by a version.
      final = Enum.reject(index_names_in_schema(), &String.ends_with?(&1, "_pkey"))
      assert length(final) == 6

      for name <- final do
        assert name in built
        assert byte_size(name) <= @max_identifier_bytes
      end

      assert @v03_name in final

      :ok = migrate(:down, @all_version, MigrateAll)
      assert index_names_in_schema() == []
    end
  end

  describe "a long :table_prefix" do
    # sabotage: named V03's index "<table>_unique_invocation_index" -> red,
    # the index came back under another cut name; restored, green.
    test "is accepted up to 48 bytes, with every index under its cut name" do
      assert byte_size(@long_prefix) == 48
      :ok = migrate(:up, @long_version, MigrateLong)

      subscriptions = @long_prefix <> "subscriptions"
      renamed = binary_part(subscriptions <> "_invocation_index", 0, @max_identifier_bytes)

      assert %{^renamed => {true, ["execution_id", "binding_id", "invoke_id"]}} =
               indexes(subscriptions)

      assert Enum.all?(index_names_in_schema(), &(byte_size(&1) <= @max_identifier_bytes))

      :ok = migrate(:down, @long_version, MigrateLong)
      assert index_names_in_schema() == []
    end

    # sabotage: dropped V01's ledger index -> the walk failed later, on
    # another relation's name, red; restored, green.
    test "fails V01 from 49 bytes, where the ledger's index name cuts to its table's" do
      assert byte_size(@too_long_prefix) == 49

      error =
        assert_raise Postgrex.Error, fn ->
          migrate(:up, @too_long_version, MigrateTooLong)
        end

      assert error.postgres.code == :duplicate_table
      assert error.postgres.message =~ @too_long_prefix <> "routing_ledger"
    end
  end
end
