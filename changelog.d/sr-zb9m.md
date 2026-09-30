### Fixed

- Migration V03 runs on SQLite, where it now does nothing: SQLite never
  shortened the subscription index name V03 renames on Postgres. V03's
  `ALTER INDEX`, which SQLite does not have, failed the migration of a
  SQLite host on 0.8.0 and later.
