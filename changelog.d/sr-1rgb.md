### Fixed

- `StatifierRouter.Addresses.reap/3` runs on SQLite: its stamp and delete
  no longer use Postgres's `= ANY(...)`, which failed any reap of a SQLite
  host on 0.8.0 and later that found a row to stamp or delete, under an
  integer or a text key; a reap with nothing to write sent no statement.
