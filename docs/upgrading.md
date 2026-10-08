# Upgrading a host from 0.6 to 0.11

This page says what a host changes to move `statifier_router` from 0.6.0 to
0.11.2, one minor at a time: 0.6 to 0.7, 0.7 to 0.8, 0.8 to 0.9, 0.9 to
0.10 and 0.10 to 0.11. A host here is the code that embeds the package: the
`StatifierRouter.Config` it builds, the migrations it runs, the bindings it
routes with, the reapers it schedules, and any front, wrapper or send
processor of its own. What each release added is in the
[changelog](https://github.com/riddler/statifier_router/blob/main/CHANGELOG.md);
this page lists only what a host has to do about it, and says **NONE** where
the answer is nothing.

Take the minors in order, and move the pin with each one, as the README's
Compatibility section recommends: `{:statifier_router, "~> 0.7.0"}`, then
`"~> 0.8.0"`, then `"~> 0.9.0"`, then `"~> 0.10.0"`, then `"~> 0.11.0"`. A
patch release rides its minor's pin, so each section below covers the
patches of the minor it moves to. The `statifier` requirement is `~> 2.9`
through 0.8 and `~> 2.10` from 0.9 on; the `statifier_persistence`
requirement stays `~> 0.18` on every step.

A host on 0.6.0 has run migration versions V01 and V02. One release in this
range adds a version to the walk, 0.8.0 (V03), and one adds a table outside
it, 0.9.0 (V04, opt-in); the last two sections of this page give both
migrations in full.

## 0.6 to 0.7

Must change: **NONE**, unless one of these is you.

- **If you set `:bindings_resolver` and read the `:unchecked` entries of
  `StatifierRouter.Contracts.check/3`**, skip or match the entry the list
  now opens with, `%{reason: :bindings_resolver, location: nil}`, before you
  read `location`: it is the one entry with no location. Keep checking each
  scope's bindings with `StatifierRouter.Contracts.undeclared_binding_events/2`.
  A configuration without a resolver gets the report it got before. This is
  the release's one **Breaking** entry.
- **If you match `StatifierRouter.Config.new/1`'s refusals exhaustively**,
  add `{:exclusive_keys, :send_handlers, :send_types}`. It is answered only
  to a configuration that gives a non-empty `:send_handlers` beside a
  `:persistence_options` carrying its own `:send_types` and no `:send_type`.

May start doing:

- **If you set `:send_type` and serve send types of your own**, declare
  them in `:send_handlers`, a map from each type string to its processor
  module. Before 0.7 such a configuration had nowhere to put them: a
  `:send_types` of your own beside `:send_type` is refused with
  `{:declared_send_types, send_type}`, so
  `StatifierRouter.Contracts.check/3` reported your types under
  `:unsupported_types`. Declared in `:send_handlers`, they join the
  router's type in the one snapshot every delivery carries, and `check/3`
  stops reporting them. A configuration without `:send_type` that passes
  its own `:send_types` in `:persistence_options` keeps working as it is.
  [How to fit the router into an engine of your own](guides/how-to-wrap-the-engine.md),
  "Step 4. Declare the send types the host serves", shows the option.

## 0.7 to 0.8

- **Add the V03 migration.** A host that has already run V02 adds one
  migration calling `StatifierRouter.Migrations.up(from: 3)`, with
  `down(from: 3, version: 3)` on rollback, passing the same options its
  first router migration passes: `:table_prefix` and `:prefix` name the
  table, and the layout options (`:leading_columns`, `:timestamps_position`,
  `:column_collations`) change nothing, since V03 creates no table.
  [V03: the subscription index name](#v03-the-subscription-index-name)
  below gives the migration in full. A first migration that calls `up/1`
  with no `version:` runs V03 on a fresh database too; one capped at
  `version: 2` does not, and the index keeps V02's name until the new
  migration runs.
- **If you match the subscription index's name as a unique violation's
  constraint** (an `Ecto.ConstraintError`, or a `unique_constraint/3`
  naming it), match `<table>_invocation_index` once V03 has run, where
  `<table>` is the subscription table's name under your `:table_prefix`.
- **If you set a `:table_prefix` of your own**, the name you read back
  before V03 depends on it. V02 named the index after the subscription
  table plus 40 bytes, so a prefix of 10 bytes or fewer kept it inside the
  63 bytes Postgres keeps of an identifier, while the default prefix,
  `"statifier_router_"`, took it to 70 and Postgres created it truncated.
  V03 finds the index under the name Postgres gave it either way, and
  renames it. `StatifierRouter.Migrations`, "Index names and a long
  `:table_prefix`", says what a long prefix does to the other index names.
- **If you run on SQLite**, do not stop at 0.8: V03's `ALTER INDEX` fails a
  SQLite migration on 0.8.0, and `StatifierRouter.Addresses.reap/3` fails
  any SQLite reap that finds a row to write. Take 0.9.2, which fixes both
  (see the next section).

May start doing:

- **If you want the router's tables keyed with a primary key of your own**,
  pass `:primary_key` to `StatifierRouter.Migrations.up/1`. It applies to
  tables a call creates, so a host already at V02 gets nothing from it.
  [How to fit the router's tables to a host](guides/how-to-fit-the-router-tables-to-a-host.md),
  "Step 3. Give the tables a primary key of the host's own", shows it.

## 0.8 to 0.9

- **Move `statifier` to 2.10 or later first.** 0.9.0 requires
  `{:statifier, "~> 2.10"}`, whether or not you set `:basichttp`.
- **NONE else for a host that does not set `:basichttp`.** No version is
  added to the walk, and `StatifierRouter.Migrations.up/1` and `down/1`
  behave as before.
- **If you run on SQLite**, take 0.9.2: on 0.9.1 V03 does nothing on
  SQLite, and on 0.9.2 `StatifierRouter.Addresses.reap/3` runs on SQLite,
  writing more than 500 rows in batches of 500, one statement each. A
  Postgres host sees the same counts.

May start doing:

- **If you want an execution to take events at an HTTP location of its
  own**, set `:basichttp` and add the opt-in location table's migration
  ([The opt-in location table](#the-opt-in-location-table) below). On such a
  configuration a binding whose `id` is `basichttp` is refused as
  `{:reserved_binding_id, "basichttp"}`, so rename one first if you have it.
  [How to give an execution an HTTP location](guides/how-to-give-an-execution-an-http-location.md)
  walks the rest.

## 0.9 to 0.10

Must change: **NONE**.

- **If you set `:basichttp` and keep a repo's query log at `:debug`**, the
  location token no longer appears in the router's own Ecto query log, but
  it is still carried by the repo's query telemetry event and by the
  execution's persisted state: never run a production repo at `:debug`.
- **If you schedule `StatifierRouter.Addresses.reap/3`**, nothing changes:
  on Postgres each batch is one array statement again, with the same
  counts. Check while you are there that your sweep pages through the
  table: one call examines at most `:limit` rows (1000 by default) and
  answers a `next` cursor, and a sweep calls again with `after: next` until
  `next` is `nil`. A host that never passes `after:` examines the first
  `:limit` rows each time and frees nothing behind them
  (`StatifierRouter.Addresses`, "Its cost is bounded";
  [How to fit the router's tables to a host](guides/how-to-fit-the-router-tables-to-a-host.md),
  "Step 1. Schedule the reapers").

May start doing:

- **If your create and step calls need a context of your own around them**
  (a tenancy, or a value your hooks read from the process), set
  `:around_delivery` on `StatifierRouter.Config`, a module exporting
  `around_delivery/3` or an arity-3 fun handed `(scope, door, work)`, that
  calls `work` exactly once and answers what it answered.
  [How to fit the router into an engine of your own](guides/how-to-wrap-the-engine.md),
  "Step 2. Wrap a whole delivery", lists the doors.

## 0.10 to 0.11

Must change: **NONE**. 0.11.1 and 0.11.2 change no code: 0.11.2 moves the
README's long sections to pages of their own, this one among them.

- **If your repo's adapter module wraps `Ecto.Adapters.SQLite3`**, take
  0.11.0 or later before you run V03: from 0.11.0 V03 does nothing on such a
  repo, as on the stock SQLite adapter, where before it sent an
  `ALTER INDEX` SQLite cannot parse. A Postgres repo, wrapped or not, is
  renamed as before.

May start doing:

- **If you set `:around_delivery` and want a send's delivery to the
  execution target wrapped too**, set `wrap_target: true` beside it. Your
  wrapper is then also handed the door `:target`, so a wrapper that
  matches its doors exhaustively adds a clause for it.
- **If your own job delivers an event back in through
  `StatifierRouter.Delivery.deliver_event/4`** and the step it drives
  reaches a route a scope in `:route_overrides` overrides, set
  `run_in_scope: true` in the envelope. Without it the route is refused as
  `{:no_delivery_scope, name}`, as before. Any value other than a boolean
  raises `ArgumentError` before anything is written.
  [How to give an execution an HTTP location](guides/how-to-give-an-execution-an-http-location.md),
  "Step 4. Send from a durable execution", shows the envelope.

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
