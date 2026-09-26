### Fixed

- The subscription table's unique index, which V02 named past the 63 bytes Postgres keeps of an identifier so that Postgres created it under a truncated name, is renamed to `<table>_invocation_index` by a new migration version, V03; a host that has already run V02 adds one migration calling `StatifierRouter.Migrations.up(from: 3)`, and `StatifierRouter.Migrations` now says what a long `:table_prefix` does to index names.
