# StatifierRouter

[![CI](https://github.com/riddler/statifier_router/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_router/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_router.svg)](https://hex.pm/packages/statifier_router)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_router.svg)](https://hex.pm/packages/statifier_router)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_router/)
[![License](https://img.shields.io/hexpm/l/statifier_router.svg)](https://github.com/riddler/statifier_router/blob/main/LICENSE)

> **Pre-1.0.** Until `statifier_router` reaches v1.0, its public surface may change
> between minor releases, sometimes drastically: a release may rename modules,
> callbacks, table columns, telemetry events or error vocabulary with no
> compatibility shim. Every such change is recorded in
> [CHANGELOG.md](CHANGELOG.md) under a bold **Breaking** heading that says what
> to do about it. Pinning to an exact minor - `~> X.Y.0` - is the recommended way
> to consume the package until 1.0.

## Broadway first

The front of this package is [Broadway](https://hexdocs.pm/broadway). The host
starts `StatifierRouter.Broadway` in its own supervision tree with any
producer it already operates, and `partition_by` keeps every message for one key
on one processor, so the events for one key reach the router one after another
instead of queueing on a lock. The partitioner is an optimisation, not the
guarantee: each delivery steps its execution under statifier_persistence's
per-execution lock and holds that lock until its transaction commits, so two
events for one execution are stepped one at a time, in the order the lock
grants them, whether or not they came through the front. Each message is
matched against the bindings, addressed, and delivered to a durable
[statifier](https://github.com/riddler/statifier-ex) execution kept by
[statifier_persistence](https://github.com/riddler/statifier_persistence),
which is created when absent.

### Starting the pipeline

`StatifierRouter.Broadway` is the pipeline. The host adds it to its own
supervision tree, after the repo, with the producer it already operates and
the router's configuration:

```elixir
children = [
  MyApp.Repo,
  {StatifierRouter.Broadway,
   name: MyApp.AdEventsRouter,
   producer: {BroadwayKafka.Producer, kafka_opts},
   router: router_config,
   processors: [default: [concurrency: 8]]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

`router_config` is a `%StatifierRouter.Config{}`. By default each message's
`scope`, `message_id` and `source` are read from its metadata and its data is
the normalized event; a producer that carries them elsewhere is paired with a
`:normalize` function of the host's own. A message whose routing returns an
error, or raises, is failed rather than passed on as a success. Whether it is
handed over again is the **producer's** contract, not Broadway's: Broadway
provides no retries of its own and acknowledges a failed message as failed
immediately. A queue-style producer that leaves an unacknowledged message
invisible for a timeout, Amazon SQS the example Broadway itself names, gives
the event back; `BroadwayKafka.Producer`, the producer in the snippet above,
acknowledges failed messages too and advances the group's offset past them, so
reprocessing is a strategy the host rolls. A host that needs a failed delivery
retried picks a producer that gives it back, or arranges the replay itself. A
binding whose `order` is `:none` is not partitioned by its key.

## What this package owns

- **Bindings**: source -> match -> key -> document -> event. `match` and
  `key` are [predicator](https://github.com/riddler/predicator-ex) programs
  evaluated over the normalized event.
- **The address table**: `(scope, document, key)` -> `execution_id`. `scope`
  is an opaque host string; the package gives it no meaning.
- **Atomic get-or-create-and-deliver**: the execution an address names is
  created when absent and handed the event in the same step.
- **Dedupe** on `(binding, message_id)` with a horizon.
- **The recorded outcome vocabulary**: every delivery attempt ends in one
  named, recorded outcome.
- **The route registry**: the named, one-way outbound destinations a chart
  reaches with `<send>`, registered per host and overridable per scope.
- **The webhook front**: `StatifierRouter.Webhook`, a Plug-shaped helper a
  host calls from its own controller or plug.
- **Execution-to-execution sends**: a `<send>` whose `target` is the reserved
  name `StatifierRouter.SendHandler.execution_target/0` resolves through the
  address table and is delivered by the same transaction a binding's delivery
  uses.
- **The source invoke**: an `<invoke>` whose lifetime is a subscription's,
  through `StatifierRouter.subscribe/3`, `StatifierRouter.cancel/2` and the
  delegate a host's own invoke handler calls,
  `StatifierRouter.SourceInvoke`.

## What it does not own

- The sinks themselves: a route adapter, what it writes to, and its
  retries are the host's.
- The invoke handler itself: the host registers it with the engine and
  delegates to `StatifierRouter.SourceInvoke`.
- Any queue adapter: Broadway's producers are the host's choice.
- Timers: those are [statifier_oban](https://github.com/riddler/statifier_oban)'s,
  and the durable queue a delayed route send is recorded on is the host's.
- A publish store: a host callback resolves a document to its active chart.
- Any process or supervisor: the host schedules the reapers and starts the
  pipeline.

## An example

An impression opens an execution of the `impression_click_join` document; a
click on the same impression lands on that same execution. Two bindings, one
document, one key:

```elixir
[
  %{id: "impressions_to_join", source: "ad_events",
    match: ~s(event.kind == "impression"), key: "event.impression_id",
    document: "impression_click_join", event: "impression.served"},
  %{id: "clicks_to_join", source: "ad_events",
    match: ~s(event.kind == "click"), key: "event.impression_id",
    document: "impression_click_join", event: "click.recorded"}
]
```

The shape is illustrative: the binding's fields are fixed by the package's
first decision record, not by this README.

### Bindings that differ by scope

`:bindings` is one list for every scope. A host whose scopes each route their
own sources to their own documents gives the configuration a
`:bindings_resolver` instead: a module implementing the
`StatifierRouter.BindingsResolver` behaviour, whose one callback takes the
event's scope and answers the `%StatifierRouter.Binding{}` structs that scope
routes by, or an arity-1 fun with that signature.

```elixir
defmodule MyApp.DepotBindings do
  @behaviour StatifierRouter.BindingsResolver

  @impl StatifierRouter.BindingsResolver
  def resolve(scope) do
    # The host's own rows, each built once with StatifierRouter.Binding.new/1
    # and cached; the router keeps no answer between calls.
    MyApp.Routing.cached_bindings(scope)
  end
end

{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    store: store,
    executor: MyApp.Executor,
    resolver: MyApp.PublishedCharts,
    chart_resolver: &MyApp.PublishedCharts.chart/1,
    bindings_resolver: MyApp.DepotBindings
  )
```

The two keys are exclusive: a configuration that gives both is refused with
`{:error, {:exclusive_keys, :bindings, :bindings_resolver}}`. The router asks
the resolver once per `StatifierRouter.route/3` call, with the event's scope,
and checks each answer as it checks the static list: a duplicated binding `id`
or the reserved one makes `route/3` return `{:error, reason}` before any
binding is evaluated. The Broadway partitioner asks it too, and
`StatifierRouter.subscribe/3` asks it for the scope of the subscribing
execution's address row. The publish-time checks take no scope, so a host
checks each scope's bindings with
`StatifierRouter.Contracts.undeclared_binding_events/2`, and hands
`StatifierRouter.Addresses.reap/3` the bindings of every scope it routes.
Without a `:bindings_resolver`, `:bindings` is read exactly as before.

## Routes and sinks

A chart reaches the outside world with `<send>`. The `type` names the
host's processor and the `target` names a **route**: an opaque string this
package resolves against the host's registry, which the engine never
parses.

```xml
<send type="myapp:sink" target="joined_records" event="joined"/>
<send type="myapp:sink" target="dead_letter" event="orphaned"/>
```

The host registers each route once and gives the handler the one type
string it answers to. `:send_type` is what puts the engine-visible
`send_types:` snapshot into `:persistence_options`, so every create and
every step of every delivery carries it:

```elixir
StatifierRouter.Config.new(
  repo: MyApp.Repo,
  store: store,
  resolver: resolver,
  chart_resolver: chart_resolver,
  bindings: bindings,
  send_type: "myapp:sink",
  route_adapters: %{
    "joined_records" => {MyApp.OutboxRoute, %{queue: "joined"}},
    "dead_letter" => {MyApp.OutboxRoute, %{queue: "orphaned"}}
  },
  route_overrides: %{"staging" => %{"joined_records" => %{queue: "staging_joined"}}},
  executor: &MyApp.Executor.execute/2
)
```

A scope overrides a route's **configuration** and never its **existence**:
a staging scope may point `joined_records` at another queue, and cannot
make a third route appear or take one away. A chart that names a route
fails the same way in every scope.

A delivery names the scope its sends resolve in. A live
`Statifier.Session` is reached by no delivery, so the host names it in the
configuration instead: `processor_scope: "staging"`, or a zero-arity fun
the handler calls once for each send and that answers the scope or `nil`.
The chart never names a scope.

A route adapter implements `StatifierRouter.Route`. It is handed its own
configuration, the built event and an idempotency key, and it answers `:ok`
or `{:error, reason}`:

```elixir
defmodule MyApp.OutboxRoute do
  @behaviour StatifierRouter.Route

  @impl true
  def deliver(%{queue: queue}, event, key) do
    MyApp.Repo.insert!(%MyApp.Outbox{queue: queue, event: event, key: key})
    :ok
  end
end
```

**A route is one-way.** It returns no data into the chart. A sink's result
- accepted, rejected, an id - comes back as a new inbound event through a
binding, correlated by the author-written send `id` the adapter echoes,
with the chart arming its own timeout as a delayed self-send. The one thing
an `{:error, _}` causes in the sending execution is `error.communication`
carrying that send's `sendid`.

**A route runs inside the delivery's transaction**, under the execution's
lock, so it may only hand off durably: a job inserted on the host's own
repo joins that transaction, which is a transactional outbox for free. It
must never call back into the sending execution, and
`StatifierRouter.Delivery.deliver/4` refuses the call it can see.

`StatifierRouter.SendHandler` is the module both host shapes reach - a
process-less host calls `handle_effect/3` from its executor, a live
`Statifier.Session` registers the module itself - and
`StatifierRouter.TimerQueue` is the durable queue a delayed route send is
recorded on, keyed by `{scope, send_id}`. The rules are ADR-0005's.

### A finished execution reaches a sink

There are two ways to tell a sink that an execution has ended, one written
in the chart and one configured in the host.

**In the chart**, a `<final>` sends on its way in. `<onentry>` on a
top-level `<final>` runs as part of the step that finishes the execution,
so the send is emitted on that step and reaches the route inside that
delivery's transaction:

```xml
<final id="joined">
  <onentry>
    <send type="myapp:sink" target="joined_records" event="pair.joined">
      <param name="impression_id" expr="impression_id"/>
    </send>
  </onentry>
</final>
```

Nothing else is needed: the send is an ordinary route send, the chart
chooses what travels in its `<param>`s, and a chart that ends in several
finals can send a different shape from each. What this pattern does not
reach is the execution's donedata, which is not addressable from
executable content; that is the second way.

**In the host**, `:on_complete` names a registered route that an
execution's donedata is handed to when a delivery through this package
finishes it, whichever `<final>` it settled in. Every door this package
owns delivers that way; a host that calls
`StatifierPersistence.Executions.create/4` or `step/5` itself reaches past
the router, and a termination reached that way fires nothing:

```elixir
StatifierRouter.Config.new(
  repo: MyApp.Repo,
  store: store,
  resolver: resolver,
  chart_resolver: chart_resolver,
  bindings: bindings,
  send_type: "myapp:sink",
  route_adapters: %{"joined_records" => {MyApp.OutboxRoute, %{queue: "joined"}}},
  on_complete: "joined_records",
  executor: &MyApp.Executor.execute/2
)
```

The route is handed a `done.execution` event whose `data` is the donedata
verbatim - `:undefined`, statifier's no-value marker, for a `<final>` that
carries none - and whose `origin` is the execution id, under an idempotency key of that execution id, the
counters the finishing step reported, and no ordinal.

The hook fires on the delivery that finishes the execution and on no
other. A later delivery to the same execution is
`{:dropped, binding_id, :finished}` and fires nothing. That is not a
convenience: donedata exists only on the answer of the call that produced
it, and a hook that re-read the execution record afterwards would be
handed `nil` every time, with no error and no warning -
`StatifierPersistence.Execution.from_record/1` sets the field to `nil` on
every struct built from a stored row, because a position that has reached
a final state has no configuration left to carry one.

A route named by `:on_complete` must be in `:route_adapters`;
`StatifierRouter.Config.new/1` refuses an unregistered name rather than
missing on the one delivery that had something to hand over. An
`{:error, _}` from the route settles that delivery as
`{:error, {:on_complete, route_name, reason}}`, which rolls it back: a
terminal execution has no `error.communication` transition left to take,
so rolling back and being redriven is the only way the hand-off is not
lost.

That makes a route that never succeeds a poison pill. The finishing
delivery never commits, so the execution stays where it was before that
step, and every time the source hands the message over again the step
re-runs, its effects are re-emitted, the route fails again and the front
sees the same message fail. Wire only a route that is safe to call again
under the same idempotency key and that eventually succeeds: this package
retries nothing and holds no failed message, so the source's own
redelivery policy is the only bound on the attempts.
`StatifierRouter.Config`'s documentation of `:on_complete` says the same
where the option is set.

## A webhook front

A provider that posts rather than queues reaches the same `route/3`. This
package adds no dependency on Plug or Phoenix: `StatifierRouter.Webhook`
is a plain function with the shape a plug or a controller action calls, and
the host writes those ten lines itself.

**The host verifies the signature.** This package verifies nothing; it
routes what it is handed.

```elixir
def create(conn, _params) do
  {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

  with :ok <- MyApp.Provider.verify(conn, raw_body) do
    answer =
      StatifierRouter.Webhook.handle(MyApp.Router.config(), %{
        scope: conn.assigns.scope,
        source: "ad_events",
        selector: %{"path" => conn.request_path},
        raw_body: raw_body,
        data: Jason.decode!(raw_body),
        provider_id: List.first(Plug.Conn.get_req_header(conn, "x-provider-event-id"))
      })

    send_resp(conn, StatifierRouter.Webhook.status(answer), "")
  end
end
```

The message id is the provider's event id when it sends a non-empty one,
and otherwise the lowercase hex SHA-256 of the raw body, so a provider's
retry of the same body is the same message. `status/1` answers `200` for
every recorded outcome - a duplicate, a drop, a refusal and a no-match
included - so the provider stops retrying, and `500` for an `{:error, _}`,
so it retries. The request's `selector` is carried for the host's own front
and is never read here: bindings are chosen by source alone.

## Resolving a document to its chart

This package keeps no publish store, so which chart a new execution of a
document starts on is the host's answer. The host gives the router's
configuration a `:resolver`: a module implementing the
`StatifierRouter.Resolver` behaviour, whose one callback takes
`(scope, document)` and answers `{content_hash, machine}` or
`{:error, reason}`. The router calls it only when it is about to create an
execution. A host with a publish store (a blocks document store, a database
table of published revisions) implements the callback over it:

```elixir
defmodule MyApp.PublishedCharts do
  @behaviour StatifierRouter.Resolver

  @impl StatifierRouter.Resolver
  def resolve(scope, document) do
    case MyApp.Publishing.active_revision(scope, document) do
      {:ok, revision} ->
        machine = MyApp.Publishing.compiled_chart(revision)
        {Statifier.Machine.identity(machine).content_hash, machine}

      :error ->
        {:error, :not_published}
    end
  end
end
```

A host whose charts are compiled at boot can use
`StatifierRouter.Resolver.Static` instead, over a map from
`{scope, document}` to a compiled machine:

```elixir
{:ok, machine} = Statifier.compile(File.read!("priv/charts/impression_click_join.scxml"))

{:ok, resolver} =
  StatifierRouter.Resolver.Static.new(%{{"7c1e", "impression_click_join"} => machine})
```

It answers the content hash of the machine's own identity, the hash
statifier_persistence records for the execution, and `{:error, :not_found}`
for a pair it does not hold. An arity-2 fun with the callback's signature is
accepted wherever a module is; `Static` returns one.

When the resolver answers `{:error, reason}`, nothing is created: the
delivery's transaction rolls back, no row of this package's is written, and
`StatifierRouter.route/3` returns
`{:error, {:unresolved_document, document, reason}}`, which a front does not
acknowledge.

An execution that already exists keeps the chart it started on, and is never
resolved through the resolver. For those the configuration takes a second,
separate callback, `:chart_resolver`, from a content hash to
`{:ok, machine}` or `:error`: the chart the execution's record names. A host
with a publish store implements both over it.

### Wrapping the create and step calls

A host whose own engine wraps statifier_persistence's two doors can hand the
configuration a stand-in for each. The delivery calls it where it would have
called persistence, with the same arguments, inside the same transaction and
savepoint, and reads its answer as it reads persistence's:

| Option | Stands in for | Takes | Answers |
|---|---|---|---|
| `:on_create` | `StatifierPersistence.Executions.create/4` | a module exporting `create/4`, or an arity-4 fun | `{:ok, execution, state}` or `{:error, reason}` |
| `:on_step` | `StatifierPersistence.Executions.step/5` | a module exporting `step/5`, or an arity-5 fun | `{:ok, execution, state}`, `{:discarded, execution}` or `{:error, reason}` |

With neither set, the delivery calls statifier_persistence itself.
`StatifierRouter.Config`'s documentation says what each receives and what an
error from it rolls back.

### Minting the execution id

By default every execution the router creates gets a UXID with the prefix
`ex`. A host that names its executions itself hands the configuration an
`:execution_id`: a module exporting `execution_id/3`, or an arity-3 fun,
taking `(scope, document, key)` and answering a non-empty string:

```elixir
defmodule MyApp.ParcelRouteIds do
  def execution_id(_scope, _document, _key) do
    "route_" <> MyApp.Ids.generate()
  end
end

{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    # ...the store, executor, resolver and chart resolver as before
    execution_id: MyApp.ParcelRouteIds
  )
```

The delivery calls it each time it is about to create an execution, and its
answer is the id on the address row, the id statifier_persistence creates the
execution under, and the id on the ledger. A duplicate delivery, and a
delivery to an address that already has an execution, never call it. Any
answer that is not a non-empty string raises `ArgumentError`. The id must be
new: an id statifier_persistence already holds is refused with
`{:error, :execution_exists}` and the delivery rolls back, so a callback that
derives the id from the address alone fails the second time that address is
filled. Under `:if_absent` a delivery that loses the race for an address row
discards the id it minted, so not every answer ends up naming an execution.

## The host schedules the reapers

This package runs no process, supervisor or scheduler. Rows that have
outlived their use are removed by plain functions the host calls on a
schedule of its own choosing.

`StatifierRouter.Dedupe.reap/2` takes the router's configuration and the
current time, deletes every dedupe row whose `expires_at` is earlier than
that time, and returns `{:ok, count}`. An expired row already counts as
absent when a delivery claims its message, so the reaper only reclaims
space: a host that never schedules it is still correct, and keeps every
row.

`StatifierRouter.Addresses.reap/2` takes the configuration and the host's
current bindings. It deletes the address rows whose execution finished longer
ago than the longest dedupe horizon of any enabled binding naming the row's
document, stamping the time it first sees an execution finished. A document no
enabled binding names has a horizon of zero, so its finished rows go at the
next reap. One call examines at most `:limit` rows and answers with a `next`
cursor; a host sweeps the table by calling again with `after: next` until
`next` is `nil`. A host that never schedules it keeps every row, which is
correct and only costs space.

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

## Placing a host column at a fixed position

Postgres appends any column an `ALTER TABLE` adds, so a host that wants
a column of its own at a fixed ordinal position on every table - a
branch column at position 2, say - cannot get it by altering the tables
afterwards. Pass `:leading_columns` to `StatifierRouter.Migrations` and
it puts the columns there when it creates the tables:

```elixir
defmodule MyApp.Repo.Migrations.AddStatifierRouter do
  use Ecto.Migration

  @opts [leading_columns: [branch_id: {:text, null: true}]]

  def up, do: StatifierRouter.Migrations.up(@opts)
  def down, do: StatifierRouter.Migrations.down(@opts)
end
```

Each entry is `name: {type, opts}`, the arguments `Ecto.Migration.add/3`
takes. The columns go immediately after `id`, in the order given, in
every table a version creates - V01's address, dedupe and routing ledger
tables and V02's subscription table - so `branch_id` above sits at
ordinal position 2 on all four. The options are the migration's, not
`StatifierRouter.Config`'s: the configuration a host routes with does
not take them. `down/1` accepts the same list and ignores it, so one
list serves both directions.

The option only places the column:

- **It applies to a fresh create.** The columns exist only in tables a
  version creates under the option. Each table is laid out by the
  version that creates it, and no version re-places a column in a table
  that already exists: a host that ran V01 without the option and adds
  it to its V02 migration gets it on the subscription table alone.
- **Defaults and `NOT NULL` belong to a later migration of your own.**
  This package's inserts never name the column (below), so a `NOT NULL`
  without a default that holds for every insert fails every write the
  package makes. Declare the column nullable here, then give it its
  default and its `NOT NULL` in your next migration with
  `ALTER COLUMN ... SET DEFAULT` and `ALTER COLUMN ... SET NOT NULL`,
  which keep it where it is. Re-adding it with `ADD COLUMN` would move it
  to the end.
- **The package never reads or writes it.** The schemas in
  `StatifierRouter.Schema` do not declare the column, so every row this
  package inserts leaves it to the column's default - `NULL` until you
  set one.

Two more options exist for a host that wrote these tables by hand and
wants the helper to build exactly what it wrote:

```elixir
@opts [
  leading_columns: [branch_id: {:text, null: true}],
  timestamps_position: :leading,
  column_collations: [execution_id: "C"]
]
```

- **`timestamps_position: :leading`** puts `inserted_at` immediately
  after the leading columns - after `id` when there are none - in every
  table that has one: the address table, the routing ledger and the
  subscription table. The dedupe table has no `inserted_at`, and the
  address table's `terminal_seen_at` stays where it is. The default,
  `:trailing`, is the layout this package has always built.
- **`column_collations: [name: collation]`** declares that package
  column with that collation wherever a version creates it: above,
  `execution_id` is `COLLATE "C"` on the address table, the routing
  ledger and the subscription table. The names it takes are the text
  columns the versions declare - `scope`, `document`, `key`,
  `execution_id`, `binding_id`, `message_id`, `outcome`, `reason` and
  `invoke_id` - and the collation must be one your database knows. A
  column of your own takes its collation in its `:leading_columns` opts
  (`collation: "C"`, which `Ecto.Migration.add/3` already accepts).

Like `:leading_columns`, both apply to a fresh create only. A malformed
value for any of the three raises `ArgumentError` before any table is
touched. Left out, every version builds exactly the tables it built
before the options existed.

To replace a hand-written migration with the helper **at the same
migration version**, so that a database that already ran it runs
nothing again:

1. Configure the options above until the helper's tables match yours.
   Prove it on a scratch database: build one copy with your migration
   and one with the helper under a different `:table_prefix`, then
   compare `information_schema.columns` (name, type, collation,
   nullability, ordinal position) and `pg_indexes` table for table,
   with the prefix stripped. The diff must be empty.
2. Replace the body of your migration with the helper calls covering
   the versions it stood in for, capped with `version:` and `from:` as
   `StatifierRouter.Migrations` describes - a migration that stood in
   for V01 alone becomes `up(@opts ++ [version: 1])` with
   `down(@opts ++ [from: 1])`. Keep the file's name and version number.

`Ecto.Migrator` records that version as already run on every existing
database, so the new body only ever runs on a fresh one, where it
builds what the comparison proved identical.

## A host that wraps the engine

Some hosts already run statifier_persistence under an engine of their own:
a stepper that stamps its own snapshot options on every create and every
step, keeps rows of its own beside each execution, and runs Oban. This
section puts the router's options for such a host into one configuration.
Each option has its own section above ("Bindings that differ by scope",
"Wrapping the create and step calls", "Minting the execution id" and
"Placing a host column at a fixed position"); this one shows how they fit
and answers what such a host meets first. The example routes a parcel's
scans from depot to doorstep:

```elixir
{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    store: store,
    executor: &MyApp.ParcelStepper.execute/2,
    resolver: MyApp.PublishedCharts,
    chart_resolver: &MyApp.PublishedCharts.chart/1,
    bindings_resolver: MyApp.DepotBindings,
    on_create: MyApp.ParcelStepper,
    on_step: MyApp.ParcelStepper,
    execution_id: MyApp.ParcelRouteIds,
    send_type: "myapp:router",
    route_adapters: %{"doorstep_photos" => {MyApp.OutboxRoute, %{queue: "photos"}}},
    timer_queue: {MyApp.ObanTimerQueue, %{}}
  )
```

and the migration places the host's own column first on every table:

```elixir
def up, do: StatifierRouter.Migrations.up(leading_columns: [depot_id: {:text, null: true}])
```

`MyApp.Router.config/0` below is the host's own: it returns this
configuration.

### Where the send types come from

`:send_type` is the one type string the router's handler answers to.
`StatifierRouter.Config.new/1` builds the `send_types:` snapshot from it,
as `Statifier.Send.Types.from_send_types(%{"myapp:router" =>
StatifierRouter.SendHandler})`, and puts it into `:persistence_options`.
The delivery hands those options to `:on_create` inside `initialize:` and
to `:on_step` beside the event. A configuration that also gives
`:persistence_options` a `:send_types` of its own is refused with
`{:error, {:declared_send_types, "myapp:router"}}`.

A stepper that registers send types of its own - here a courier
processor beside the router's handler - stamps its own snapshot in the
hooks, built from a map that keeps the router's type on
`StatifierRouter.SendHandler`:

```elixir
defmodule MyApp.ParcelStepper do
  alias StatifierPersistence.Executions

  def create(store, execution_id, machine, opts) do
    types = send_types()
    opts = Keyword.update(opts, :initialize, [send_types: types], &Keyword.put(&1, :send_types, types))
    Executions.create(store, execution_id, machine, opts)
  end

  def step(store, execution_id, machine, event, opts) do
    opts = Keyword.put(opts, :send_types, send_types())

    with {:ok, execution, state} <- Executions.step(store, execution_id, machine, event, opts) do
      # The host's own row, inside the delivery's transaction.
      MyApp.ParcelLog.record!(execution, event)
      {:ok, execution, state}
    end
  end

  # Each handler ignores the effects that are not its own.
  def execute(effect, context) do
    with :ok <- StatifierRouter.SendHandler.handle_effect(MyApp.Router.config(), effect, context) do
      MyApp.Courier.handle_effect(effect, context)
    end
  end

  defp send_types do
    Statifier.Send.Types.from_send_types(%{
      "myapp:router" => StatifierRouter.SendHandler,
      "myapp:courier" => MyApp.Courier
    })
  end
end
```

The publish-time checks read the configuration, not the hooks:
`StatifierRouter.Routes.unsupported_types/2`, and so the `:unsupported_types`
of `StatifierRouter.Contracts.check/3`, judges a chart against the snapshot on
`:persistence_options`, so a `<send type="myapp:courier">` is reported
there. The host judges its charts against its own snapshot with
`Statifier.Send.Types.unsupported_sends/2`.

### Where `put_config/1` is called

At the executor seam it is not: `StatifierRouter.SendHandler.handle_effect/3`
is handed the configuration by the host's executor, as `execute/2` above
does, and a host whose executions are all stepped behind the executor
seam never calls `put_config/1`.

`StatifierRouter.SendHandler.put_config/1` is for a live
`Statifier.Session` that registers `StatifierRouter.SendHandler` under the
router's type. The session's `perform/2` is handed no configuration and
reads it from the process it runs in, which is the session's own, so the
host calls `put_config/1` in that process before a send is performed
there. In a process that holds none, `perform/2` answers
`{:error, {:no_config, StatifierRouter.SendHandler}}`, which says nothing
about the send and is not reported to the chart; any other
`{:error, reason}` from `perform/2` the host reports with
`Statifier.Session.failed_send/3`. The session's sends resolve their
routes in the scope the configuration's `:processor_scope` names.

### A timer queue over the host's Oban

A `<send>` of the router's type with a `delay` is recorded on the
`:timer_queue`, a module implementing `StatifierRouter.TimerQueue`. Over
an Oban the host already runs, the queue needs:

- **The router's repo.** At the executor seam `schedule/2` and `cancel/3`
  are called inside the sending step's transaction, under the execution's
  lock, so an Oban that inserts through the repo `:repo` names commits or
  rolls back with the step.
- **One held row per dedup key.** `schedule/2` adds no second row for an
  `entry.key` the queue already holds, and answers `:ok`.
- **Cancel by `{scope, send_id}`.** `cancel/3` deletes that scope's rows
  for the send id and no other scope's, and answers `{:ok, count}`.
- **The row as the one decision point.** A fire deletes the row in the
  write that decides it fires, so a cancel and a fire of one row cannot
  both succeed. Below, the rows live in a table of the host's and an Oban
  job only wakes one.
- **The fire-time check, then the delivery.** A row whose owner has ended
  is deleted and not delivered; otherwise the route is found with
  `StatifierRouter.Config.route/3` and handed the row's own `config`,
  `event` and `key`. `StatifierRouter.TimerQueue`'s "Firing a row" says
  how each owner is checked.

```elixir
defmodule MyApp.ObanTimerQueue do
  @behaviour StatifierRouter.TimerQueue

  @impl StatifierRouter.TimerQueue
  def schedule(_queue_config, entry) do
    # MyApp.Timers.hold/1 inserts the entry unless a row with its key is
    # held, answering {:ok, row} or {:ok, nil} when one already is.
    case MyApp.Timers.hold(entry) do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        at = DateTime.add(DateTime.utc_now(), entry.delay_ms, :millisecond)

        case Oban.insert(MyApp.TimerFire.new(%{"row_id" => row.id}, scheduled_at: at)) do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl StatifierRouter.TimerQueue
  def cancel(_queue_config, scope, send_id),
    do: {:ok, MyApp.Timers.delete_all(scope, send_id)}
end

defmodule MyApp.TimerFire do
  use Oban.Worker, queue: :timers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"row_id" => row_id}}) do
    MyApp.Repo.transaction(fn ->
      # MyApp.Timers.take/1 deletes the row and answers its entry, or nil
      # when a cancel deleted it first.
      with %{} = entry <- MyApp.Timers.take(row_id),
           true <- MyApp.Timers.owner_live?(entry.scope),
           {:ok, {module, _registered}} <-
             StatifierRouter.Config.route(MyApp.Router.config(), nil, entry.route),
           {:error, reason} <- module.deliver(entry.config, entry.event, entry.key) do
        # Undoes the take, so Oban's retry finds the row again.
        MyApp.Repo.rollback(reason)
      end
    end)
  end
end
```

### What `:no_timer_queue` at publish means

`StatifierRouter.Contracts.check/3` lists, under `:unregistered_routes`,
every `<send>` of the router's type that is never handed to the route its
literal `target` names. An entry with `reason: :no_timer_queue` is a send
that writes a literal `delay` to a registered route, on a configuration
with no `:timer_queue`:

```elixir
%{route: "doorstep_photos", location: location, reason: :no_timer_queue}
```

At run time that send is refused as `{:no_timer_queue, send_id}` and
nothing is queued. At the executor seam the sender hears
`error.communication` carrying the send's `sendid`, and the step it sent
from stands; on a live session `perform/2` answers the refusal for the
host to report. `:timer_queue` is one value for every scope, so the
finding holds in every scope, and the remedy is a queue on the
configuration rather than a change to the chart. A `delayexpr` is not
judged, so a chart with no entry may still send a delay the queue is
needed for. Whether the finding blocks a publish is the host's decision.

## Versioning

statifier_persistence retires a chart it can prove nothing still needs, and
`StatifierPersistence.Executions.retire_chart/4` refuses the retirement while
anything pins the chart's content hash. It counts the pins in its own tables
itself and asks the host's pin sources for the ones it cannot see. An address
row is one it cannot see: the row lives in this package's table, and it is why
a later event still reaches the execution it names.

Most of the time this package's vote only names the router in the refusal: the
rows it counts name `:active` executions, and an `:active` execution on the
hash refuses the retirement on its own. The vote decides the answer in one
window: `retire_chart/4` reads the active ids before its transaction opens, and
an execution that goes terminal between that read and the guarded write inside
the transaction no longer refuses on its own. The address count, taken from
the ids read earlier, still does.

`StatifierRouter.PinSource` is this package's answer. The callback takes no
configuration, so the host binds its own in a module it names at the retire
call, and `use StatifierRouter.PinSource` is how this package spells that
module:

```elixir
defmodule MyApp.RouterPins do
  # MyApp.Router.config/0 is the host's own: it returns the
  # %StatifierRouter.Config{} the host routes events with.
  use StatifierRouter.PinSource, config: MyApp.Router.config()
end

StatifierPersistence.Executions.retire_chart(store, content_hash, [MyApp.RouterPins],
  retired_by: "myapp:publisher"
)
```

The module answers `%{addresses: n}`: the number of address rows naming one of
the active executions on the hash, which the retire call hands every source as
`:execution_ids`. An address row carries an `execution_id` and no content hash,
so those ids are the only handle this table can answer on, and the hash itself
is not read.

Nothing forces the macro: a host can write the same module by hand, with
`@behaviour StatifierPersistence.PinSource` and a `pins/2` that calls
`StatifierRouter.PinSource.count/2` with its configuration. Name the host's
module at the retire call, never `StatifierRouter.PinSource` itself: it
defines no `pins/2`, so naming it refuses the retirement as a pin source
failure.

The pin releases when the execution leaves the `:active` set, not when its
address row is deleted: the next retire call no longer asks about that
execution, and counts one address fewer. Nothing in the pin source retains a
row or deletes one; the row stands until `StatifierRouter.Addresses.reap/2`
stamps it terminal and deletes it once the horizon has elapsed.

## Status

Every piece named under "What this package owns" is built in this release.
The Broadway front is `StatifierRouter.Broadway`. The binding is
`StatifierRouter.Binding`. The tables behind the rest - the address table,
the dedupe table, the routing ledger and the subscription table - are
created by `StatifierRouter.Migrations` and read through the schemas in
`StatifierRouter.Schema`. `StatifierRouter.route/3` evaluates the bindings
for an event and writes the ledger row of a refusal, and
`StatifierRouter.Delivery`, its default delivery module, gets or creates the
execution an address names and steps the event into it in one transaction,
under each of the three `create` modes, after claiming the message for the
binding in the same transaction with `StatifierRouter.Dedupe`. The chart a
new execution starts on is the host's `StatifierRouter.Resolver`, or
`StatifierRouter.Resolver.Static` over charts compiled at boot. The host
schedules the two reapers, `StatifierRouter.Dedupe.reap/2` and
`StatifierRouter.Addresses.reap/2`. The outbound half is the registry on
`StatifierRouter.Config`, the adapter behaviour `StatifierRouter.Route`,
the queue behaviour `StatifierRouter.TimerQueue`, and
`StatifierRouter.SendHandler`, which serves both shapes a registered
type's send reaches a host in. A send whose `target` names no registered
route is reported to the sender, leaves the step it was sent from standing,
and writes one `send_refused` routing-ledger row;
`StatifierRouter.SendHandler` says what each of that row's columns holds.
The source invoke is `StatifierRouter.subscribe/3`,
`StatifierRouter.cancel/2` and the delegate
`StatifierRouter.SourceInvoke`, over the subscription table
`StatifierRouter.Migrations.V02` adds. Each piece lands behind the
decision record that fixes it, in [docs/adr/](https://github.com/riddler/statifier_router/blob/main/docs/adr/README.md).

## Installation

```elixir
def deps do
  [
    {:statifier_router, "~> 0.6.0"}
  ]
end
```

## License

MIT - see [LICENSE](https://github.com/riddler/statifier_router/blob/main/LICENSE).
