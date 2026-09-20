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
error, or raises, is failed rather than acknowledged, so the source hands it
over again. A binding whose `order` is `:none` is not partitioned by its key.

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
- **The webhook front**: `StatifierRouter.Webhook`, a Plug-shaped helper a
  host calls from its own controller or plug.

## What it does not own

- Sinks and the route registry.
- Execution-to-execution sends.
- The source invoke.
- Any queue adapter: Broadway's producers are the host's choice.
- Timers: those are [statifier_oban](https://github.com/riddler/statifier_oban)'s.
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

## Status

Every piece named under "What this package owns" is built in this release.
The Broadway front is `StatifierRouter.Broadway`. The binding is
`StatifierRouter.Binding`. The tables behind the rest - the address table,
the dedupe table and the routing ledger - are created by
`StatifierRouter.Migrations` and read through the schemas in
`StatifierRouter.Schema`. `StatifierRouter.route/3` evaluates the bindings
for an event and writes the ledger row of a refusal, and
`StatifierRouter.Delivery`, its default delivery module, gets or creates the
execution an address names and steps the event into it in one transaction,
under each of the three `create` modes, after claiming the message for the
binding in the same transaction with `StatifierRouter.Dedupe`. The chart a
new execution starts on is the host's `StatifierRouter.Resolver`, or
`StatifierRouter.Resolver.Static` over charts compiled at boot. The host
schedules the two reapers, `StatifierRouter.Dedupe.reap/2` and
`StatifierRouter.Addresses.reap/2`. Each piece lands behind the decision
record that fixes it, in [docs/adr/](docs/adr/README.md).

## Installation

```elixir
def deps do
  [
    {:statifier_router, "~> 0.1.0"}
  ]
end
```

## License

MIT - see [LICENSE](https://github.com/riddler/statifier_router/blob/main/LICENSE).
