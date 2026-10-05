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
