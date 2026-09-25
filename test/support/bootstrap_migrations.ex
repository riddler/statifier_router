defmodule StatifierRouter.BootstrapMigrations do
  @moduledoc """
  The suite-wide DDL bootstrap: the package's tables under the default
  options and statifier_persistence's tables for
  `StatifierRouter.TestPersistence`, applied once by `test/test_helper.exs`
  through `Ecto.Migrator` (idempotent on `:already_up`) and left in place. The SQL sandbox rolls
  each test's rows back, so only the DDL persists from one suite to the next.

  The live migration tests in `StatifierRouter.MigrationsTest` do not use
  these tables: they own their DDL end to end, up and down, under a table
  prefix and a Postgres schema of their own. Test-only support code.
  """

  @migrations [
    {20_260_919_000_101, __MODULE__.DefaultTables},
    {20_260_919_000_102, __MODULE__.PersistenceTables},
    {20_260_919_000_103, __MODULE__.SubscriptionsTable},
    {20_260_925_000_104, __MODULE__.PersistenceEndedAt}
  ]

  defmodule DefaultTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierRouter.Migrations

    # Pinned at V01 in both directions, so this migration does not drift
    # forward when the package gains a version: a later version gets a
    # bootstrap migration of its own, as a host's would.
    def up, do: Migrations.up(version: 1)
    def down, do: Migrations.down(from: 1)
  end

  defmodule SubscriptionsTable do
    @moduledoc false
    use Ecto.Migration

    alias StatifierRouter.Migrations

    # What a host already running V01 writes for V02, and the reason this
    # is a second migration rather than an edit of the one above: `from:`
    # is inclusive, so `from: 2` runs V02 and does not re-run V01's
    # `CREATE TABLE` against tables that already exist.
    def up, do: Migrations.up(from: 2, version: 2)
    def down, do: Migrations.down(from: 2, version: 2)
  end

  defmodule PersistenceTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    # statifier_persistence's tables, which the delivery tests create and
    # step executions in, through StatifierRouter.TestPersistence. Capped
    # at V07, the newest version statifier_persistence 0.13 shipped, so a
    # database this ran against before stays the one the next migration
    # upgrades, as a host's would.
    def up, do: Migrations.up(for: StatifierRouter.TestPersistence, version: 7)
    def down, do: Migrations.down(for: StatifierRouter.TestPersistence, from: 7)
  end

  defmodule PersistenceEndedAt do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    # What a host already at V07 writes for statifier_persistence 0.17 and
    # later: `from:` is inclusive, so `from: 8` runs V08 (the executions
    # table's `ended_at`) and nothing before it.
    def up, do: Migrations.up(for: StatifierRouter.TestPersistence, from: 8, version: 8)
    def down, do: Migrations.down(for: StatifierRouter.TestPersistence, from: 8, version: 8)
  end

  @doc "Applies every bootstrap migration, tolerating `:already_up`."
  @spec up(module()) :: :ok
  def up(repo) do
    for {version, module} <- @migrations do
      case Ecto.Migrator.up(repo, version, module, log: false) do
        :ok -> :ok
        :already_up -> :ok
      end
    end

    :ok
  end
end
