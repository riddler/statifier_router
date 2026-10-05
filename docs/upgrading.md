# Upgrading the tables

A package release that adds a migration version needs one more migration of
the host's own, starting where the last one stopped. Each release
that adds one says so in the Upgrading paragraph of its
[changelog](https://github.com/riddler/statifier_router/blob/main/CHANGELOG.md)
entry. This page gives the migrations for V03 and for the opt-in location
table in full.

## V03: the subscription index name

V03 renames the subscription table's unique index, which V02 named past the
63 bytes Postgres keeps of an identifier, so Postgres created it under a
truncated name. A host that has already run V02 adds:

```elixir
defmodule MyApp.Repo.Migrations.RenameStatifierRouterSubscriptionIndex do
  use Ecto.Migration

  def up, do: StatifierRouter.Migrations.up(from: 3)
  def down, do: StatifierRouter.Migrations.down(from: 3, version: 3)
end
```

with the same `:table_prefix` and `:prefix` its earlier migrations pass.
Nothing is rebuilt, and on a database where the index already carries its new
name the migration does nothing. A first migration that calls `up/1` with no
`version:`, as the README's Installation does, runs every version this
package knows, so on a fresh database it runs V03 too; the migration above is
still needed for every database that ran the first one before V03 existed,
and on a fresh one it finds the index already renamed.
`StatifierRouter.Migrations` says what a long `:table_prefix` does to the
index names.

## The opt-in location table

V04, the location table a configuration with `:basichttp` keeps its tokens in
(see [How to give an execution an HTTP location](guides/how-to-give-an-execution-an-http-location.md)),
is opt-in (ADR-0002, the Amendment of 2026-09-30 "the location table is
opt-in, outside the version walk"): it is not in the version walk, so `up/1`
and `down/1`, capped or not, never create, drop or require it, and every
migration above behaves exactly as it did before V04 existed. A host that does
not set the key needs nothing. One that does adds a migration of its own after
the ones it has:

```elixir
defmodule MyApp.Repo.Migrations.AddStatifierRouterLocations do
  use Ecto.Migration

  def up, do: StatifierRouter.Migrations.up_locations()
  def down, do: StatifierRouter.Migrations.down_locations()
end
```

with the same `:table_prefix`, `:prefix`, layout options and `:primary_key`
its earlier migrations pass; the two calls take no `:from` or `:version`.
`up_locations/1` creates only what is missing and `down_locations/1` drops the
table only if it is there. The table references the address table, so it has
to go before V01's tables do: as a later migration, this one is rolled back
first, which is the order Ecto's rollback takes.
