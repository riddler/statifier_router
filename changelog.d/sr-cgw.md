### Added

- `StatifierRouter.Migrations.up/1` takes `:leading_columns`, `:timestamps_position` and `:column_collations`, statifier_persistence's layout options under the same spellings and rules: host-owned columns immediately after `id`, `inserted_at` moved to follow them, and a collation per package text column, applied only as a version creates a table, on all four tables. `down/1` accepts and ignores them. Left out, the tables are built exactly as before.
