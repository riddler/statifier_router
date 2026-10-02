### Changed

- `StatifierRouter.Addresses.reap/3` binds each batch of ids as one array
  on Postgres again (`= ANY(...)`), so Postgres prepares one statement per
  write rather than one per batch length; SQLite and every other adapter
  keep the `IN (...)` list, and every reap answers the same counts.
