# How to fit the router's tables to a host

This guide makes the router's tables live by the host's rules: rows that have
outlived their use are reaped on the host's schedule, a column of the host's
own sits at a fixed position on every table, and the primary key follows the
host's id convention. It starts from a host repo with migrations of its own
and the router configuration it routes with.

Steps 2 and 3 shape tables when a version creates them, so take them before
the first migration that runs the router's versions; Step 1 can come at any
time.

## Step 1. Schedule the reapers

This package runs no process, supervisor or scheduler. Rows that have
outlived their use are removed by plain functions the host calls on a
schedule of its own choosing.

`StatifierRouter.Dedupe.reap/2` takes the router's configuration and the
current time, deletes every dedupe row whose `expires_at` is earlier than that
time, and returns `{:ok, count}`. An expired row already counts as absent when
a delivery claims its message, so the reaper only reclaims space: a host that
never schedules it is still correct, and keeps every row.

`StatifierRouter.Addresses.reap/2` takes the configuration and the host's
current bindings. It deletes the address rows whose execution finished longer
ago than the longest dedupe horizon of any enabled binding naming the row's
document, stamping the time it first sees an execution finished. A document no
enabled binding names has a horizon of zero, so its finished rows go at the
next reap. One call examines at most `:limit` rows and answers with a `next`
cursor; a host sweeps the table by calling again with `after: next` until
`next` is `nil`. A host that never schedules it keeps every row, which is
correct and only costs space.

That horizon is the knob for a late event. While the row lives, a late event
for a finished execution is recorded as `dropped: finished`; once a reap has
deleted it, an event through a `create: :if_absent` binding opens a second
execution for the key. A host whose latest partner event can arrive after the
horizon lengthens `horizon_ms` on a binding naming the document, or sets
`create: :never` on the partner's binding, so its late event is recorded as
`dropped: no_execution` instead; the cost of `:never` is that a partner
arriving before the event that opens the execution is dropped the same way. A
document reached only through the execution target has no binding naming it,
so its horizon is zero.

A host that runs [Oban](https://hexdocs.pm/oban) would write a worker and a
cron entry like these; this package depends on neither:

```elixir
defmodule MyApp.RouterDedupeReaper do
  use Oban.Worker, queue: :maintenance

  @impl Oban.Worker
  def perform(_job) do
    # MyApp.Router.config/0 is the host's own: it returns the
    # %StatifierRouter.Config{} the host routes events with.
    {:ok, _count} = StatifierRouter.Dedupe.reap(MyApp.Router.config(), DateTime.utc_now())
    :ok
  end
end

# config/config.exs
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"@hourly", MyApp.RouterDedupeReaper}]}
  ]
```

The reaper ran when its job completes and `{:ok, count}` matched; a raise
there fails the job, and Oban retries it.

## Step 2. Place a host column at a fixed position

Postgres appends any column an `ALTER TABLE` adds, so a host that wants a
column of its own at a fixed ordinal position on every table - a depot column
at position 2, say - cannot get it by altering the tables afterwards. Pass
`:leading_columns` to `StatifierRouter.Migrations` and it puts the columns
there when it creates the tables:

```elixir
defmodule MyApp.Repo.Migrations.AddStatifierRouter do
  use Ecto.Migration

  @opts [leading_columns: [depot_id: {:text, null: true}]]

  def up, do: StatifierRouter.Migrations.up(@opts)
  def down, do: StatifierRouter.Migrations.down(@opts)
end
```

Each entry is `name: {type, opts}`, the arguments `Ecto.Migration.add/3`
takes. The columns go immediately after `id`, in the order given, in every
table a version creates - V01's address, dedupe and routing ledger tables and
V02's subscription table - so `depot_id` above sits at ordinal position 2 on
all four. The options are the migration's, not `StatifierRouter.Config`'s:
the configuration a host routes with does not take them. `down/1` accepts the
same list and ignores it, so one list serves both directions. The opt-in
location table ([Upgrading the tables](../upgrading.md)) is outside that walk:
`up_locations/1` takes the same list and places the columns there the same
way.

A name a table the call creates already declares is refused: a
`:leading_columns` entry named like any column `StatifierRouter.Migrations.V01`
lists for the address, dedupe or routing ledger table, or
`StatifierRouter.Migrations.V02` lists for the subscription table, raises
`ArgumentError` naming the column and the tables that declare it, before any
DDL runs, where Postgres would otherwise refuse the `CREATE TABLE` with a
duplicate column. A name only a table the call does not create declares is a
host column like any other: `up(from: 2)` may lead with `expires_at`, which
only V01's dedupe table has, and `up(version: 1)` with `invoke_id`, which only
V02's subscription table has. Without `:primary_key`, the primary key is the
repo's `:migration_primary_key` and is not checked: a repo that sets it to
`false` may lead with an `id` of its own. With `:primary_key` set (Step 3),
the package declares `id` itself, and a leading `id` raises like any other
package column.

The option only places the column:

- **It applies to a fresh create.** The columns exist only in tables a
  version creates under the option. Each table is laid out by the version
  that creates it, and no version re-places a column in a table that already
  exists: a host that ran V01 without the option and adds it to its V02
  migration gets it on the subscription table alone.
- **Defaults and `NOT NULL` belong to a later migration of your own.** This
  package's inserts never name the column (below), so a `NOT NULL` without a
  default that holds for every insert fails every write the package makes.
  Declare the column nullable here, then give it its default and its
  `NOT NULL` in your next migration with `ALTER COLUMN ... SET DEFAULT` and
  `ALTER COLUMN ... SET NOT NULL`, which keep it where it is. Re-adding it
  with `ADD COLUMN` would move it to the end.
- **The package never reads or writes it.** The schemas in
  `StatifierRouter.Schema` do not declare the column, so every row this
  package inserts leaves it to the column's default - `NULL` until you set
  one.

Two more options exist for a host that wrote these tables by hand and wants
the helper to build exactly what it wrote:

```elixir
@opts [
  leading_columns: [depot_id: {:text, null: true}],
  timestamps_position: :leading,
  column_collations: [execution_id: "C"]
]
```

- **`timestamps_position: :leading`** puts `inserted_at` immediately after
  the leading columns - after `id` when there are none - in every table that
  has one: the address table, the routing ledger and the subscription table.
  The dedupe table has no `inserted_at`, and the address table's
  `terminal_seen_at` stays where it is. The default, `:trailing`, is the
  layout this package has always built.
- **`column_collations: [name: collation]`** declares that package column
  with that collation wherever a version creates it: above, `execution_id` is
  `COLLATE "C"` on the address table, the routing ledger and the subscription
  table. The names it takes are the text columns the versions declare -
  `scope`, `document`, `key`, `execution_id`, `binding_id`, `message_id`,
  `outcome`, `reason` and `invoke_id` - and the collation must be one your
  database knows. A column of your own takes its collation in its
  `:leading_columns` opts (`collation: "C"`, which `Ecto.Migration.add/3`
  already accepts). On SQLite the option builds no collation: the package
  hands each entry to `add/3` as `:collation`, which the Postgres adapter
  reads, while ecto_sqlite3 reads `:collate`, so every entry is accepted and
  every column keeps SQLite's default collation.

Like `:leading_columns`, both apply to a fresh create only. A malformed value
for any of the three raises `ArgumentError` before any table is touched. Left
out, every version builds exactly the tables it built before the options
existed.

To replace a hand-written migration with the helper **at the same migration
version**, so that a database that already ran it runs nothing again:

1. Configure the options above until the helper's tables match yours. Prove
   it on a scratch database: build one copy with your migration and one with
   the helper under a different `:table_prefix`, then compare
   `information_schema.columns` (name, type, collation, nullability, ordinal
   position) and `pg_indexes` table for table, with the prefix stripped. The
   diff must be empty.
2. Replace the body of your migration with the helper calls covering the
   versions it stood in for, capped with `version:` and `from:` as
   `StatifierRouter.Migrations` describes - a migration that stood in for V01
   alone becomes `up(@opts ++ [version: 1])` with `down(@opts ++ [from: 1])`.
   Keep the file's name and version number.

`Ecto.Migrator` records that version as already run on every existing
database, so the new body only ever runs on a fresh one, where it builds what
the comparison proved identical.

## Step 3. Give the tables a primary key of the host's own

Every table the versions create has an `id` primary key, and by default it is
the one the host repo's `:migration_primary_key` gives every table: a
`bigserial` unless the repo says otherwise. A host whose tables follow another
id convention - a sortable string id, say - passes `:primary_key` with the
id's type and the default the database fills it in with:

```elixir
defmodule MyApp.Repo.Migrations.AddStatifierRouter do
  use Ecto.Migration

  def up, do: StatifierRouter.Migrations.up(opts())
  def down, do: StatifierRouter.Migrations.down(opts())

  defp opts do
    [primary_key: [type: :text, default: fragment("gen_random_uuid()::text")]]
  end
end
```

The option takes `:type`, required, and `:default`, optional, each what
`Ecto.Migration.add/3` takes, and builds the `id` of every table a version
creates - V01's address, dedupe and routing ledger tables and V02's
subscription table - with them, in place of the repo's key for these tables
alone. The column is always named `id`. The opt-in location table is outside
the version walk; `up_locations/1` takes the same option, and a host that sets
it for V01 passes it there too, since the location table's `address_id` takes
the address table's key type.

- **The database fills the id in.** The package inserts no id of its own, so
  the key needs a default: a function, a sequence, or an identity column's
  own. A key with no default fails every insert the package makes.
- **The schemas read it back as the column holds it.** The schemas in
  `StatifierRouter.Schema` take the id through `StatifierRouter.Schema.Id`: an
  integer from an integer column, a string from a text one. It casts exactly
  as Ecto's own `:id` type does, so a text id is never cast: look a row up
  with a where clause that binds the id uncast, not with `Repo.get/2` or a
  changeset cast. The package's own reads never cast an id either.

  ```elixir
  import Ecto.Query

  MyApp.Repo.one(
    from a in StatifierRouter.Config.queryable(config, StatifierRouter.Schema.Address),
      where: fragment("? = ?", a.id, ^id)
  )
  ```
- **The address sweep follows the id's order.**
  `StatifierRouter.Addresses.reap/2` pages through the address table in the id
  column's order, and its `next` cursor is an id as the table holds it - a
  string under a text key, which the next call passes back as `after:`. A
  sortable id sweeps roughly in insertion order; any id sweeps the whole
  table.
- **It applies to a fresh create.** Like the layout options above, it types
  the key of the tables a version creates and re-types no table that already
  exists: a host that ran V01 under the repo's key and sets it for V02 gets the
  new key on the subscription table alone. Decide the key before the first
  migration. Left out, every table is built exactly as before the option
  existed.

With the option set, the package declares `id` itself, so a
`:leading_columns` entry named `id` raises `ArgumentError`.

The migration worked when every router table's `id` has the type you gave and
a first routed event writes its rows without an insert error.
