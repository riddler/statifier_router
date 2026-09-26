### Fixed

- `StatifierRouter.Migrations.up/1` raises `ArgumentError` naming the column and the tables before any DDL runs when a `:leading_columns` name is one a table the call creates already declares (`scope`, `inserted_at` and the like; the primary key the repo configures is not checked), where the migration before failed inside Postgres with a duplicate column error. A name only a table outside the call declares, such as `expires_at` under `up(from: 2)`, is accepted as before.
