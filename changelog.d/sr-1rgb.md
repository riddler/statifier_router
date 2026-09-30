### Fixed

- `StatifierRouter.Addresses.reap/3` runs on SQLite: its stamp and delete
  no longer use Postgres's `= ANY(...)`, which failed every reap of a
  SQLite host on 0.8.0 and later, under an integer or a text key.
