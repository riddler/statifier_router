# What the router owns, and what it leaves to the host

The router sits between the systems that report on a parcel and the durable
execution that tracks it. It owns the rows that decide which execution an
event reaches and what happened to the event; it leaves to the host every
process, every external system and every choice about which chart is
published. This page names both sides, says where each piece lives in the
package, and explains why an address row counts when a chart is retired.

## What this package owns

- **Bindings**: source -> match -> key -> document -> event. `match` and `key`
  are [predicator](https://github.com/riddler/predicator-ex) programs
  evaluated over the normalized event.
- **The address table**: `(scope, document, key)` -> `execution_id`. `scope`
  is an opaque host string; the package gives it no meaning.
- **Atomic get-or-create-and-deliver**: the execution an address names is
  created when absent and handed the event in the same step.
- **Dedupe** on `(binding, message_id)` with a horizon.
- **The recorded outcome vocabulary**: every delivery attempt this package
  routes ends in one named outcome, and every outcome but `no_match` writes
  one routing-ledger row: a delivery, a duplicate, each drop, a `key_refused`
  and a `send_refused` whose sender has an address row. These write none. A
  `no_match` is reported as telemetry only. A send refused because its sending
  execution has no address row (`unaddressed_sender`, and a delayed send's
  `delay` refusal from such a sender) is reported to the sender only, because
  the ledger's `scope` is `NOT NULL` and such a sender has no scope. A delivery
  that answers `{:error, _}` is not an outcome: it ends the attempt with
  nothing written for that binding, and the rows of the bindings before it
  stay written. A timer firing into an execution is not routed here (timers
  are statifier_oban's, below) and writes no routing-ledger row.
- **The route registry**: the named, one-way outbound destinations a chart
  reaches with `<send>`, registered per host and overridable per scope. A
  route a scope overrides resolves in the scope of the delivery that drove the
  sending step, or in the configuration's `:processor_scope` on the
  send-processor shape; a step a host drives itself through
  `StatifierRouter.Delivery.deliver_event/4` names its scope with
  `run_in_scope: true` in the envelope.
- **The webhook front**: `StatifierRouter.Webhook`, a Plug-shaped helper a
  host calls from its own controller or plug.
- **The BasicHTTP front**: `StatifierRouter.BasicHTTP`, the W3C Basic HTTP
  Event I/O Processor for durable executions, gives each execution created
  under a new address row of a configuration that sets `:basichttp` a
  location, kept in the opt-in location table;
  `StatifierRouter.BasicHTTP.Front`, Plug-shaped as the webhook front is,
  delivers a POST to that location into its execution. See
  [How to give an execution an HTTP location](../guides/how-to-give-an-execution-an-http-location.md).
- **The whole-delivery wrapper**: the configuration's optional
  `:around_delivery`, handed `(scope, door, work)`, runs every read and write
  of a delivery on the doors this package drives itself inside one call of the
  host's. With `:wrap_target` set beside it, it also wraps a send's delivery
  to an execution target that no other door's work encloses, under the door
  `:target`. See
  [How to fit the router into an engine of your own](../guides/how-to-wrap-the-engine.md).
- **Execution-to-execution sends**: a `<send>` whose `target` is the reserved
  name `StatifierRouter.SendHandler.execution_target/0` resolves through the
  address table and is delivered by the same transaction a binding's delivery
  uses.
- **The source invoke**: an `<invoke>` whose lifetime is a subscription's,
  through `StatifierRouter.subscribe/3`, `StatifierRouter.cancel/2` and the
  delegate a host's own invoke handler calls, `StatifierRouter.SourceInvoke`.

## What it does not own

- The sinks themselves: a route adapter, what it writes to, and its retries
  are the host's.
- The invoke handler itself: the host registers it with the engine and
  delegates to `StatifierRouter.SourceInvoke`.
- Any queue adapter: Broadway's producers are the host's choice.
- Timers: those are [statifier_oban](https://github.com/riddler/statifier_oban)'s,
  and the durable queue a delayed route send is recorded on is the host's.
- A publish store: a host callback resolves a document to its active chart.
- Any process or supervisor: the host schedules the reapers and starts the
  pipeline.

The line falls where a choice stops being about routing. Which producer, which
sink, which retry policy and which chart is live are decisions a host has
already made for its own reasons, often in systems this package cannot see;
the router taking any of them would mean a second place to configure them and
a process of its own to keep alive. What the router does keep is the state
that has to change in the same transaction as the execution's step - the
dedupe claim, the address row and the ledger row - because nowhere else can
write them atomically with it.

## Where each piece lives

Every piece named above is built. The Broadway front is
`StatifierRouter.Broadway`. The binding is `StatifierRouter.Binding`. The
tables behind the rest - the address table, the dedupe table, the routing
ledger and the subscription table - are created by `StatifierRouter.Migrations`
and read through the schemas in `StatifierRouter.Schema`.
`StatifierRouter.route/3` evaluates the bindings for an event and writes the
ledger row of a refusal, and `StatifierRouter.Delivery`, its default delivery
module, gets or creates the execution an address names and steps the event
into it in one transaction, under each of the three `create` modes, after
claiming the message for the binding in the same transaction with
`StatifierRouter.Dedupe`. The chart a new execution starts on is the host's
`StatifierRouter.Resolver`, or `StatifierRouter.Resolver.Static` over charts
compiled at boot. The host schedules the two reapers,
`StatifierRouter.Dedupe.reap/2` and `StatifierRouter.Addresses.reap/2`.

The outbound half is the registry on `StatifierRouter.Config`, the adapter
behaviour `StatifierRouter.Route`, the queue behaviour
`StatifierRouter.TimerQueue`, and `StatifierRouter.SendHandler`, which serves
both shapes a registered type's send reaches a host in. A send whose `target`
names no registered route is reported to the sender, leaves the step it was
sent from standing, and writes one `send_refused` routing-ledger row;
`StatifierRouter.SendHandler` says what each of that row's columns holds. The
source invoke is `StatifierRouter.subscribe/3`, `StatifierRouter.cancel/2` and
the delegate `StatifierRouter.SourceInvoke`, over the subscription table
`StatifierRouter.Migrations.V02` adds. The BasicHTTP front is
`StatifierRouter.BasicHTTP` and `StatifierRouter.BasicHTTP.Front`, over the
opt-in location table that `StatifierRouter.Migrations.up_locations/1` creates
outside the version walk; a configuration without `:basichttp` needs neither.
The whole-delivery wrapper is the configuration's optional `:around_delivery`,
with `:wrap_target` its opt-in for the execution target's delivery; left out,
nothing is called. Each piece lands behind the decision record that fixes it,
in [docs/adr/](https://github.com/riddler/statifier_router/blob/main/docs/adr/README.md).

## Where a source event's data lands

A host that keeps a posted form's values out of the engine's state needs to
know which rows a source event reaches. A source event carries a `scope`, a
`message_id`, a `source` and its `data`, the adapter-normalized event. A
binding reads that data three ways: its `match` and `key` programs evaluate
over it, and its `data` paths project it (`StatifierRouter.Binding.project/2`).
The router writes the rows below and makes two calls into
statifier_persistence; those rows and those calls are everything it writes of
the event.

**The router's own rows.** The package writes five tables, each through one
schema in `StatifierRouter.Schema`; the location table only under a
configuration that sets `:basichttp`. The list below is every column each
schema maps, under the default `table_prefix`, and what it holds of a source
event:

| Table | Column | What it holds of a source event |
|---|---|---|
| `statifier_router_addresses` | `id` | nothing: the table's own id |
| `statifier_router_addresses` | `scope` | the event's `scope` |
| `statifier_router_addresses` | `document` | nothing: the binding's `document` |
| `statifier_router_addresses` | `key` | the value the binding's `key` program produced over the event |
| `statifier_router_addresses` | `execution_id` | nothing: a minted id, or the host's `:execution_id` answer, which is handed the scope, the document and the key |
| `statifier_router_addresses` | `terminal_seen_at` | nothing: when a reap or a delivery first read the execution finished |
| `statifier_router_addresses` | `inserted_at` | nothing: the delivery attempt's time |
| `statifier_router_dedupe` | `id` | nothing: the table's own id |
| `statifier_router_dedupe` | `binding_id` | nothing: the binding's `id` |
| `statifier_router_dedupe` | `message_id` | the event's `message_id` |
| `statifier_router_dedupe` | `expires_at` | nothing: the attempt's time plus the binding's dedupe horizon |
| `statifier_router_routing_ledger` | `id` | nothing: the table's own id |
| `statifier_router_routing_ledger` | `binding_id` | nothing: the binding's `id` |
| `statifier_router_routing_ledger` | `message_id` | the event's `message_id` |
| `statifier_router_routing_ledger` | `scope` | the event's `scope` |
| `statifier_router_routing_ledger` | `outcome` | nothing: the outcome's name |
| `statifier_router_routing_ledger` | `key` | the key, on every outcome `StatifierRouter.Delivery` records; `nil` on a `key_refused` |
| `statifier_router_routing_ledger` | `execution_id` | nothing: the execution the outcome names, or `nil` |
| `statifier_router_routing_ledger` | `reason` | on a `key_refused` only, the refusal as `inspect/1` renders it: the value a `match` or `key` program produced, or the evaluation error it raised; `nil` on every other outcome of a source event |
| `statifier_router_routing_ledger` | `inserted_at` | nothing: the delivery attempt's time |
| `statifier_router_subscriptions` | `id` | nothing: the table's own id |
| `statifier_router_subscriptions` | `binding_id` | nothing: the binding the source invoke names |
| `statifier_router_subscriptions` | `execution_id` | nothing: the subscribing execution |
| `statifier_router_subscriptions` | `invoke_id` | nothing: the invocation's id |
| `statifier_router_subscriptions` | `scope` | a copy of the subscribing execution's address row `scope` |
| `statifier_router_subscriptions` | `key` | a copy of the subscribing execution's address row `key` |
| `statifier_router_subscriptions` | `inserted_at` | nothing: when `StatifierRouter.subscribe/3` wrote it |
| `statifier_router_locations` | `id` | nothing: the table's own id |
| `statifier_router_locations` | `address_id` | nothing: the address row the location belongs to |
| `statifier_router_locations` | `token` | nothing: random bytes `StatifierRouter.BasicHTTP` mints |
| `statifier_router_locations` | `inserted_at` | nothing: when the location was first written |

Three things the table implies are worth saying outright. The webhook
front's `raw_body` is never written: when no provider id is handed over, the
message id is the body's SHA-256 in hex (`StatifierRouter.Webhook`), and only
that digest reaches the rows. A `key_refused` row's `reason` is event data
at rest: a `key` that produced a number, or a `match` that produced a
string, stores that value, and predicator's type mismatch error carries the
values it compared. And a host's `:leading_columns` are columns the
migrations place and the package never writes; a host fills them through
its own wrap, if at all. A `send_refused` row records a chart's `<send>`,
not a source event; `StatifierRouter.SendHandler` says what its columns hold.

**The two calls into statifier_persistence.** `StatifierRouter.Delivery`
creates an execution with `create/4` and steps it with `step/5`, or calls a
host's `:on_create` and `:on_step` with the same arguments:

- `create/4` is handed the execution id, the chart and the options: the
  executor and an `initialize:` snapshot of the configuration's persistence
  options, carrying a location token when the configuration sets
  `:basichttp`. It is handed no message id, no key and no data, and the
  router seeds nothing into the new execution's datamodel.
- `step/5` is handed one external event, named by the binding's `event`,
  whose data is the binding's projection of the event's data: the paths the
  binding's `data` names, and nothing outside them. On an adapter that keeps
  an input log, statifier_persistence keeps that event, data and all, as
  delivered (`StatifierPersistence.Executions.inputs/2`). The
  execution's datamodel then holds whatever the chart itself copies out of
  `_event.data`.

The telemetry a `no_match` reports names the binding, the source, the scope
and the message id, and no data.

**The rule for a host.** Of a source event, the router keeps at rest its
scope, its message id and the key its binding produced, and, on a refused
`match` or `key`, what that program produced or the error it raised;
statifier_persistence keeps the binding's projection in the input log and
whatever the chart copies from it. A field of the event that no binding's
`match`, `key` or `data` reads is written nowhere by this package. So a host
that keeps form values out of the engine's state keys its bindings on an id
of its own, projects only ids, and routes an event whose data carries only
ids, as [Step 5 of the webhook guide](../guides/how-to-take-webhooks-and-form-posts.md#step-5-a-form-post-you-store-first)
does.

## Why an address row pins a chart

statifier_persistence retires a chart it can prove nothing still needs, and
`StatifierPersistence.Executions.retire_chart/4` refuses the retirement while
anything pins the chart's content hash. It counts the pins in its own tables
itself and asks the host's pin sources for the ones it cannot see. An address
row is one it cannot see: the row lives in this package's table, and it is
why a later event still reaches the execution it names.

Most of the time this package's vote only names the router in the refusal: the
rows it counts name `:active` executions, and an `:active` execution on the
hash refuses the retirement on its own. The vote decides the answer in one
window: `retire_chart/4` reads the active ids before its transaction opens,
and an execution that goes terminal between that read and the guarded write
inside the transaction no longer refuses on its own. The address count, taken
from the ids read earlier, still does.

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
`:execution_ids`. An address row carries an `execution_id` and no content
hash, so those ids are the only handle this table can answer on, and the hash
itself is not read.

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
