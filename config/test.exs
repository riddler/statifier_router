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

# Keeps the harness quiet: Ecto logs every query at :debug.
config :logger, level: :warning
