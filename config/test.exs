import Config

# The test harness is a real Postgres server (docker compose or a local
# server locally, a service container in CI), reached through these PG* env
# vars so every environment configures the same repo without a mix.exs edit.
# Defaults match docker-compose.yml's `db` service.
config :statifier_router, StatifierRouter.TestRepo,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: System.get_env("PGDATABASE", "statifier_router_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The Oban instance the corpus's Oban run mode schedules its timers on
# (test/support/corpus_runner.ex), over the same repo. Manual testing mode
# runs no queue, plugin or stager: a job fires only when the runner drains
# it, at the time the case's clock says it falls due.
config :statifier_router, StatifierRouter.TestOban,
  name: StatifierRouter.TestOban,
  repo: StatifierRouter.TestRepo,
  testing: :manual

# Keeps the harness quiet: Ecto logs every query at :debug.
config :logger, level: :warning
