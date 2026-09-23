# Database-backed tests are ordinary tests in the ordinary suite, against a
# real Postgres server - no tag skips them when the server is absent (the
# harness statifier_persistence records in its sp-ADR-0005). Create the test
# database if it does not exist yet, start the repo, and put the SQL sandbox
# in :manual mode so each test checks out its own connection.
#
# Two modules take real Postgres locks outside the sandbox: the live
# migration tests (migrations_test.exs) and the delivery race tests
# (delivery_race_test.exs). Each switches the one shared repo to :auto,
# a mode that applies to the whole repo rather than to the module that
# set it. A run holding the migration module next to the async suite
# deadlocked (40P01) in tests that module does not contain, async: false
# notwithstanding. Both modules carry `@moduletag :isolated`, the default
# run excludes that tag, and a second, separate `--only isolated` run
# (`mix test --only isolated` by hand) takes them in an OS process of
# their own. `mix quality` runs both
# (the "Isolated tests" stage in .quality.exs), and so does CI, which
# runs `mix quality`. A module that sets :auto, or otherwise holds real
# locks outside the sandbox, takes the tag.
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

ExUnit.start(exclude: [:isolated])
