### Fixed

- `StatifierRouter.Migrations.V03` does nothing, as on
  `Ecto.Adapters.SQLite3`, for a repo whose adapter module is another one
  that writes its SQL with the stock SQLite connection (a wrapper around
  `Ecto.Adapters.SQLite3`), where it sent an `ALTER INDEX` SQLite cannot
  parse. Postgres repos, wrapped or not, are renamed as before.
