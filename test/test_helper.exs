# Database-backed tests are ordinary tests in the ordinary suite, against a
# real Postgres server - no tag skips them when the server is absent (the
# harness statifier_persistence records in its sp-ADR-0005). Create the test
# database if it does not exist yet, start the repo, and put the SQL sandbox
# in :manual mode so each test checks out its own connection. The live
# migration tests (migrations_test.exs, async: false) switch the repo to
# :auto for their own DDL and restore :manual afterward.
{:ok, _} = Application.ensure_all_started(:postgrex)

case Ecto.Adapters.Postgres.storage_up(StatifierRouter.TestRepo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _pid} = StatifierRouter.TestRepo.start_link()

# The package tables under the default options, created once for the whole
# suite, idempotently. Only DDL persists - the sandbox rolls rows back.
:ok = StatifierRouter.BootstrapMigrations.up(StatifierRouter.TestRepo)

Ecto.Adapters.SQL.Sandbox.mode(StatifierRouter.TestRepo, :manual)

ExUnit.start()
