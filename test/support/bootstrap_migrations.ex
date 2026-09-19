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
    {20_260_919_000_102, __MODULE__.PersistenceTables}
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

  defmodule PersistenceTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    # statifier_persistence's tables, which the delivery tests create and
    # step executions in, through StatifierRouter.TestPersistence.
    def up, do: Migrations.up(for: StatifierRouter.TestPersistence)
    def down, do: Migrations.down(for: StatifierRouter.TestPersistence)
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
