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

**In the host**, `:on_complete` names a registered route that every
finished execution's donedata is handed to, whichever `<final>` it settled
in:

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

## Versioning

statifier_persistence retires a chart it can prove nothing still needs, and
`StatifierPersistence.Executions.retire_chart/4` refuses the retirement while
anything pins the chart's content hash. It counts the pins in its own tables
itself and asks the host's pin sources for the ones it cannot see. An address
row is one it cannot see: the row lives in this package's table, and it is why
a later event still reaches the execution it names, so a chart retired under
it would leave that event routed to an execution whose chart is gone.

`StatifierRouter.PinSource` is this package's answer. It writes the module a
host names at the retire call:

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

The pin releases when the address does. Nothing in the pin source retains a
row or deletes one: an execution finishes, `StatifierRouter.Addresses.reap/2`
stamps its row terminal and deletes it once the horizon has elapsed, and the
next retire call counts one address fewer.

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
    {:statifier_router, "~> 0.3.0"}
  ]
end
```

## License

MIT - see [LICENSE](https://github.com/riddler/statifier_router/blob/main/LICENSE).
