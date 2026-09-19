### Added

- `StatifierRouter.Migrations`: `up/1` and `down/1` create and drop the address table, the dedupe table and the routing ledger from a host's one-line delegating migration, with `from:`, `version:`, `table_prefix:` and `prefix:` options.
- `StatifierRouter.Config`: `new/1` resolves the host's repo, table prefix and Postgres schema, and `table/2`, `put_meta/2` and `queryable/2` point the `StatifierRouter.Schema` modules at the configured tables.
- `StatifierRouter.Schema.Address`, `StatifierRouter.Schema.Dedupe` and `StatifierRouter.Schema.Ledger`: Ecto schemas over the three tables.
