# StatifierRouter

[![CI](https://github.com/riddler/statifier_router/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_router/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_router.svg)](https://hex.pm/packages/statifier_router)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_router.svg)](https://hex.pm/packages/statifier_router)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_router/)
[![License](https://img.shields.io/hexpm/l/statifier_router.svg)](https://github.com/riddler/statifier_router/blob/main/LICENSE)

Delivers external events to the right durable [statifier](https://github.com/riddler/statifier-ex)
execution, creating it when absent, for Elixir developers whose events arrive
from other systems, late or twice. Bindings pick the execution, an address
table remembers it, dedupe records the second copy instead of delivering it,
and one key's events step one at a time.

## Why this package

A parcel is scanned at the depot, by the carrier and by the van's handheld,
and each system reports it on its own schedule: a scan arrives late, a webhook
is retried, the doorstep scan lands before the depot's. Every one of those
events belongs to the one durable execution that tracks that parcel, which has
to exist from the first scan on. Written by hand, that is a lookup table from
parcel to execution, a dedupe table, a lock, and one transaction around all
three, for every source.

With this package you declare bindings instead: which source, which events,
which key, which document. Each event is routed in one transaction on
[statifier_persistence](https://github.com/riddler/statifier_persistence): the
dedupe claim, the address lookup or the create, the step, and a ledger row
naming the outcome. A retried webhook is recorded as a duplicate, a late scan
for a finished parcel is recorded as dropped, and two scans of one parcel step
its execution one after the other. The package starts no process: the host
starts the [Broadway](https://hexdocs.pm/broadway) pipeline in its own tree
and schedules the reapers.

## Installation

```elixir
def deps do
  [
    {:statifier_router, "~> 0.11.0"}
  ]
end
```

The router's tables come from one migration of the host's own, run after
statifier_persistence's
([`StatifierPersistence.Ecto.Migrations`](https://hexdocs.pm/statifier_persistence/StatifierPersistence.Ecto.Migrations.html)):

```elixir
defmodule MyApp.Repo.Migrations.AddStatifierRouter do
  use Ecto.Migration

  def up, do: StatifierRouter.Migrations.up()
  def down, do: StatifierRouter.Migrations.down()
end
```

## Basic usage

Two systems scan the same parcel, one sending its id as a number and one as a
padded string; both bindings trim it to one key, so both reach one execution.
`MyApp.Persistence` is the host's `use StatifierPersistence.Ecto, repo:
MyApp.Repo` module.

```elixir
{:ok, machine} = Statifier.compile(File.read!("priv/charts/parcel_delivery.scxml"))
hash = Statifier.Machine.identity(machine).content_hash
{:ok, store} = StatifierPersistence.Storage.new(StatifierPersistence.Storage.Ecto, persistence: MyApp.Persistence)
{:ok, resolver} = StatifierRouter.Resolver.Static.new(%{{"depot_north", "parcel_delivery"} => machine})

{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    store: store,
    executor: fn _effect, _context -> :ok end,
    resolver: resolver,
    chart_resolver: fn ^hash -> {:ok, machine} end,
    bindings: [
      %{id: "depot_scans", source: "depot_scanners", match: ~s(event.kind == "scan"),
        key: "trim(event.parcel_id::string)", document: "parcel_delivery", event: "parcel.scanned"},
      %{id: "carrier_scans", source: "carrier", match: ~s(event.kind == "delivered"),
        key: "trim(event.parcel_id::string)", document: "parcel_delivery", event: "parcel.delivered"}
    ]
  )

scan = %{scope: "depot_north", source: "depot_scanners", message_id: "scan-881",
         data: %{"kind" => "scan", "parcel_id" => 1042771}}

StatifierRouter.route(config, scan)
#=> {:ok, [{:created_and_delivered, "depot_scans", "ex_..."}]}

StatifierRouter.route(config, scan)
#=> {:ok, [{:duplicate, "depot_scans"}]}

StatifierRouter.route(config, %{scope: "depot_north", source: "carrier", message_id: "c-77",
                                data: %{"kind" => "delivered", "parcel_id" => " 1042771 "}})
#=> {:ok, [{:delivered, "carrier_scans", "ex_..."}]}
```

The second copy of the scan is recorded and not delivered, and the carrier's
event reaches the execution the depot's scan created.

## Documentation

- Learn
  - [Basic usage](#basic-usage): two sources, one parcel, one execution, and a duplicate recorded rather than delivered.
- Do
  - [How to route a producer's messages through the Broadway pipeline](docs/guides/how-to-run-the-broadway-pipeline.md): the pipeline in the host's tree, its configuration, and what a failed message does.
  - [How to bind events from several sources to one execution](docs/guides/how-to-bind-events-to-an-execution.md): bindings, a key program that normalizes, and bindings that differ by scope.
  - [How to deliver a chart's sends to a sink](docs/guides/how-to-deliver-to-a-sink.md): routes, a transactional outbox end to end, and a finished execution's hand-off.
  - [How to take webhooks and form posts](docs/guides/how-to-take-webhooks-and-form-posts.md): the webhook front, the host's signature check, the message id and the status.
  - [How to give an execution an HTTP location](docs/guides/how-to-give-an-execution-an-http-location.md): the BasicHTTP front, its tokens, and sending from a durable execution.
  - [How to resolve a document to its chart](docs/guides/how-to-resolve-a-document-to-its-chart.md): the resolver behaviour, the static resolver, and the chart an existing execution keeps.
  - [How to fit the router into an engine of your own](docs/guides/how-to-wrap-the-engine.md): the create and step hooks, the whole-delivery wrapper, execution ids, send types and a timer queue.
  - [How to fit the router's tables to a host](docs/guides/how-to-fit-the-router-tables-to-a-host.md): the reapers, a host column at a fixed position, and a primary key of the host's own.
  - [Upgrading a host from 0.6 to 0.11](docs/upgrading.md): what a host changes for each minor, the V03 migration, and the opt-in location table.
- Look up
  - [The configuration](https://hexdocs.pm/statifier_router/StatifierRouter.Config.html): every option, its default and how it is checked.
  - [The binding](https://hexdocs.pm/statifier_router/StatifierRouter.Binding.html): its fields, their defaults and the key rules.
  - [Routing and its outcomes](https://hexdocs.pm/statifier_router/StatifierRouter.html): `route/3`, the outcome vocabulary and what each outcome writes.
  - [The migrations](https://hexdocs.pm/statifier_router/StatifierRouter.Migrations.html): the versions, their options and the table prefix.
  - [The conformance corpus](https://github.com/riddler/statifier_router/blob/main/corpus/README.md): the language-neutral cases and their format.
  - [The changelog](https://github.com/riddler/statifier_router/blob/main/CHANGELOG.md): what changed in each version, with every breaking change marked.
- Understand
  - [What the router owns, and what it leaves to the host](docs/explanation/what-the-router-owns.md): the pieces, where each lives, and why an address row pins a chart.
  - [Why one key's events step one at a time](docs/explanation/one-key-at-a-time.md): the partitioner, the per-execution lock, the ceiling it sets and the ways around it.
  - [The decision records](https://github.com/riddler/statifier_router/tree/main/docs/adr): why bindings, addressing, delivery, routes and the fronts are shaped the way they are.

## Compatibility

The package needs Elixir 1.18 or later (`elixir: "~> 1.18"` in `mix.exs`). It
builds on `statifier ~> 2.10`, `statifier_persistence ~> 0.18`,
`predicator ~> 9.4`, `broadway ~> 1.3` and `ecto_sql ~> 3.14`, and brings no
database driver: the host's repo does. Its CI runs the suite against
Postgres, and the migrations are also run on SQLite.

Until 1.0, the public surface may change between minor releases: a release may
rename modules, callbacks, table columns, telemetry events or error vocabulary
with no compatibility shim. Every such change is recorded in the
[changelog](https://github.com/riddler/statifier_router/blob/main/CHANGELOG.md)
under a bold **Breaking** heading that says what to do about it, and pinning
to an exact minor, `~> X.Y.0`, is the recommended way to take the package
until then.

## License

MIT - see [LICENSE](https://github.com/riddler/statifier_router/blob/main/LICENSE).
