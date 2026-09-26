# ADR-0005: Routes: the send type names the host's processor and the route name rides in `target`, a per-host registry whose scopes override a route's config and never its existence, one-way delivery whose only chart-visible outcome is a transport failure, an idempotency key the router composes from the effect's deterministic identity and the seam's context, one handler module for both host shapes, and the unregistered-route miss

Status: accepted

## Context

ADR-0001 through ADR-0004 answer the inbound half: an external event
arrives, a binding claims it, and one durable execution steps it. This
record answers the outbound half. A chart reaches the outside world with
`<send>`, and the question is what a `<send>` that is meant for the host
looks like, who owns the thing it names, and what the host owes when it
performs it twice.

The four nouns are ADR-0001's. A **document** is the stable thing an
author edits; a **revision** is one saved state of it; a **chart** is what
a revision compiles to; an **execution** is one durable, stepped instance
of one chart. A **route** is the fifth noun this record adds: a named,
one-way outbound destination a host registers, which a chart names without
knowing what is behind it.

### The records this one reads

Cited throughout by their own names, and here once by path so a reader can
open them:

- `docs/adr/0001-bindings.md` - a binding is host configuration; an inbound
  event reaches an execution through one.
- `docs/adr/0002-addressing.md` - the address table, the opaque `scope`
  compared only for equality, and the opaquely minted execution id.
- `docs/adr/0003-delivery-discipline.md` - the delivery record: one
  transaction per delivery, `step/5` inside it, and section 2's statement
  that a rollback does not un-fire the effects the executor was handed.
- `docs/adr/0004-the-refusal-and-drop-vocabulary.md` - the refusal and drop
  vocabulary, and the routing ledger a refusal is recorded on.
- The engine's durable-timer record, `statifier-ex`'s
  `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
  (st-ADR-0054), which fixes the cancellation key `{session scope, send_id}`
  and the separate dedup key, and says the two are not one key.
- The engine's send-type record, `statifier-ex`'s
  `docs/adr/0069-host-registered-send-types.md` (st-ADR-0069), which put the
  Event I/O Processor slot on `type`.
- statifier_persistence's executor seam,
  `lib/statifier_persistence/executor.ex`, and its lifecycle,
  `lib/statifier_persistence/executions.ex`.

The versions those surfaces were read at, because neither is in this
package's dependency tree today, and the two dependencies are short of them
for **different reasons**. The engine surfaces - `Statifier.Effect.Send`,
`SendDelayed` and `Cancel`, `Statifier.Send.Processor`,
`Statifier.Send.Event`, `Statifier.Send.Types`,
`Statifier.Session.failed_send/3`, st-ADR-0054 and st-ADR-0069 - were read
at statifier **2.6.0**. This package's constraint, `~> 2.5`, already admits
2.6.0; what holds the tree at 2.5.0 is `mix.lock`, so statifier needs a
**dependency update and no constraint change at all**. The persistence
surfaces - `StatifierPersistence.Executor`,
`StatifierPersistence.Executions`'s contract order and persist tail, and the
`send_types:` option decision 6 rests on - were read at
statifier_persistence **0.13.0**, which the constraint `~> 0.12.0` excludes
outright, so that one needs a **constraint bump as well as the update**.
Either way a reader will not find these surfaces in the current tree until
that work lands; it is separate from this record, which only states what it
read and where.

### What the engine already decided

The `type` attribute of `<send>` is the Event I/O Processor slot, and a
host fills it by registering a module for a type string
(st-ADR-0069, `statifier-ex`'s
`docs/adr/0069-host-registered-send-types.md`, decision 1). For a
registered type the engine delivers nothing itself and never parses
`target`: `Statifier.Send.Processor`'s moduledoc states that `target` is
"the processor's own opaque route string: the library never parses it".
The refusal for an unregistered type is a pure, pre-start check outside
the validator, `Statifier.Send.Types.unsupported_sends/2`.

A registered type's send reaches a host in **two shapes**, and this
package must serve both from one place:

- **A live `Statifier.Session`** calls the registered module's
  `Statifier.Send.Processor` callbacks: `deliver/3` and `cancel/2` are
  pure planning callbacks with no process, no clock and no I/O, returning
  instructions; `perform/2` is the impure half, and the behaviour's own
  moduledoc says it "MAY be called more than once for the same send".
- **A process-less host** - which is what this package is - receives
  `%Statifier.Effect.Send{}`, `%Statifier.Effect.SendDelayed{}` and
  `%Statifier.Effect.Cancel{}` at `StatifierPersistence.Executor.execute/2`
  and builds the event itself with `Statifier.Send.Event.build/3`. The
  seam's context is exactly `%{execution_id: String.t(), content_hash:
  String.t()}` (`StatifierPersistence.Executor`'s `@type context`).

### The ordering, and what it gives this record

The executor seam does **not** run after the execution is written. It runs
**before** the write, inside the persist tail.
`StatifierPersistence.Executions`'s moduledoc states the order as the
contract: liveness check -> load -> re-stamp `routes`/`invoke_types`/
`send_types` -> step -> execute effects via the executor seam -> consume
`:done` and `:budget_exhausted` -> assert the internal queue is empty ->
persist. Its `persist_tail/7` is that order in code: it splits the
lifecycle effects off, builds the seam context, reports, executes the
executable effects, and only then calls its write. The thing that runs
after the write is that package's own step reporter, never a host's.

That order is the ground for everything this record decides about
repetition. The same moduledoc states the property: effect execution is
at-least-once, a crash between step and persist re-drives the same event
and re-emits the same effects with identical deterministic keys, and "this
loop never dedupes - idempotency is the consumer's". This package's own
ADR-0003 section 2 says the same thing from the transaction's side: a
rollback after `step/5` does not un-fire the effects the executor was
handed, and the redelivery re-emits them. `StatifierRouter.Delivery`'s
moduledoc already records it in the package's own words.

So a route may be called for work that is then rolled back, and may be
called again for the same logical send. The route contract has to be
written from that, not from a durability guarantee the seam does not give.

### What a key can be built from

There is no `position` on either surface. The executor seam's context
carries `execution_id` and `content_hash` and nothing else. A
`%Statifier.Effect.Send{}` carries `event`, `target`, `type`, `data`,
`send_id`, `c_index`, `owner`, `macrostep`, `microstep`, `round`,
`ordinal` and `id_from_author?`. `%Statifier.Effect.SendDelayed{}` carries
those plus `delay_ms` and `caller_context`, with `ordinal` enforced rather
than optional. `%Statifier.Effect.Cancel{}` carries only `send_id`,
`c_index`, `owner`, the three counters, `ordinal` and `caller_context` -
no `event`, no `target`, no `type`.

`ordinal` is minted only for a send whose type the session registered, or
for a delayed send (`Statifier.Effect.Send`'s moduledoc on the field). The
engine names the components itself: `Statifier.Send.Processor`'s moduledoc
requires a processor to be idempotent "on the ADR-0054 decision 3 dedup
key's components read off the effect: the send id, the step counters,
`c_index`, `owner`, and `ordinal` ... with the session scope the host
supplies". The bare `ADR-0054` inside that quotation is the engine's own
record, st-ADR-0054, `statifier-ex`'s
`docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md` - not a
record of this repository, which has 0001 to 0005 only. That record also
fixes the **cancellation** key, `{session scope, send_id}`, which is a
different key from the dedup key quoted here; decision 5 uses both.

### Delayed sends do not survive a resume

`Statifier.Send.Processor`'s moduledoc states that the session's record of
which processor holds which delayed send id is "the live session's own
state", not part of the persisted `Statifier.Position`, so a resumed
session holds nothing and a `<cancel>` it runs reaches no processor. A
host whose processor keeps such a send across a resume "cancels or fires
it by its own record, keyed by the send id and the session scope". This
package is driven process-less and resumes on every delivery, so that case
is not an edge here: it is the normal one.

### The failure path is real and must not be legislated away

An adapter's failure is not silent. On the process-less shape
`StatifierPersistence.Executions`'s `reentry_origin/1` maps a `:send` and a
`:send_delayed` failure to `{{:content, c_index, owner}, [sendid:
send_id]}`, so an executor's `{:error, reason}` re-enters the sending
execution as `error.communication` carrying the send's `sendid`, in the
same step, before the write. On the live shape the host reports the same
miss through `Statifier.Session.failed_send/3`. A record that forbade the
chart ever hearing from a route outright would contradict that guarantee.

### The example used throughout

The advertising impression-and-click join of ADR-0003 and ADR-0004: one
execution per impression, joining a click to it. Its outbound half is two
routes - `joined_records`, where a completed join is handed off, and
`dead_letter`, where a click that found no impression is parked.

## Decision

### 1. The chart spelling: the type names the processor, the target names the route

An outbound send is written with the route name in `target` and the host's
processor in `type`:

    <send type="myapp:sink" target="joined_records" event="joined">
      <param name="impression_id" expr="impression_id"/>
    </send>

The `type` is the string the host registered a `Statifier.Send.Processor`
under (st-ADR-0069 decision 1). The `target` is the **route name**: an
opaque string this package resolves against the host's registry, which the
engine never parses.

A host scheme in `target` - a URL, a queue URI, a broker address, anything
that names a transport rather than a route - is refused by this record. A
chart names a route; what the route is wired to is the host's, and moving
that wiring is a configuration change that no document is edited for.

### 2. The registry is per host; a scope overrides a route's config, never its existence

The route registry is host configuration, carried on
`StatifierRouter.Config` beside `:bindings`: a map from route name to the
adapter that serves it, with that adapter's configuration.

A **scope** - ADR-0002's opaque host string, compared only for equality -
may override the **configuration** of a route the host registered, and
never its **existence**. One scope cannot add a route another does not
have, and cannot remove one. A chart that names `joined_records` names the
same route in every scope; what differs is where that scope's
`joined_records` writes.

Nothing about routes is per execution. An execution names routes; it does
not own them, configure them, or carry them in its position.

### 3. A route is one-way: it returns no data, and a sink's result comes back as a new inbound event

A route is **one-way**. The route callback receives the built event and the
idempotency key of decision 4, and returns `:ok | {:error, term()}`,
meaning handed off or not handed off. It returns no data.

The return carries **no result** into the chart. The one event a route can
cause in the sending execution is `error.communication` with the send's
`sendid`: from an `{:error, _}` at the executor seam, in the same step, or
from `Statifier.Session.failed_send/3` on a live session. That is
**transport failure, not an answer**. This rule does not forbid it, and an
adapter that swallowed it would break the engine's guarantee that a failed
send is never dropped silently.

A sink's **result** - accepted, rejected, an id, retries exhausted - is a
**new inbound event through a binding** (ADR-0001), delivered after the
commit by the adapter's own worker or by the sink's webhook. An adapter's
worker calling `StatifierRouter.route/3` with an API response is permitted
and is not the route answering: it is an ordinary inbound delivery that
the same dedupe, addressing and outcome vocabulary govern as any other
(ADR-0003, ADR-0004).

**Correlation** is the author's, not the package's. The chart names the
request with an author-written send `id` (or `idlocation`); the adapter
echoes that id in the result's data and derives the result's message id
from it, which is what makes the inbound delivery dedupable under ADR-0003
section 6. The chart arms its own timeout with a delayed self-send.

### 4. The idempotency key is composed by the router, from the effect and the shape's context

Neither surface supplies an idempotency key. The **router composes one**
and hands it to the route with the event; the adapter owes at-most-once on
it.

The key is conceptually the execution, where in the step the send sat, and
the ordinal. Two of those three are read directly; the middle one has no
single field behind it, because there is no `position` on either surface.
The executor seam's context carries `execution_id` and `content_hash` and
nothing else, and a send effect carries `event`, `target`, `type`, `data`,
`send_id`, `c_index`, `owner`, `macrostep`, `microstep`, `round`,
`ordinal` and `id_from_author?`. The key is therefore composed, not
supplied, and it is composed from fields that exist:

- **The effect half**, read off the `%Statifier.Effect.Send{}` or
  `%Statifier.Effect.SendDelayed{}`: `send_id`, the step counters
  `macrostep`, `microstep` and `round`, `c_index`, `owner`, and `ordinal`.
  Those are exactly the components `Statifier.Send.Processor`'s moduledoc
  requires a processor to be idempotent on, and together they are what
  "where in the step the send sat" means in fields. `ordinal` is present
  on every registered-type send and on every delayed send, and it is what
  separates two sends agreeing on every other component - two iterations
  of a `<foreach>` writing the same author-written `id`.
- **The scope half**, which is the only part that differs by host shape:
  `execution_id` from the seam context at the executor seam
  (`StatifierPersistence.Executor`'s `@type context`), and `session_id`
  from the `ctx` map on the send-processor shape
  (`Statifier.Send.Processor`'s `t:ctx/0`).

One honest limit, and it follows from ADR-0003 section 2. A rollback after
`create/4` rolls the execution back, and the redelivery creates again
under a newly minted id, which ADR-0002 forbids deriving from anything
stable. The effect half of the key is identical across that pair; the
scope half is not, so an adapter keyed on the whole key sees the second
firing as new work. This record does not paper over that: it is the
documented cost of stepping inside the transaction, and an adapter whose
downstream cannot tolerate it dedupes on the effect half together with a
binding-supplied business key instead.

### 5. One handler module serves both host shapes; at the executor seam it hands off durably and never re-enters, and it owns delayed sends itself

One module serves both shapes. It implements `Statifier.Send.Processor`
for a live session, and it offers a function an executor calls with the
effect and the seam context - `StatifierPersistence.Executor`'s
`execute/2` shape. Both entry points compose the same key by decision 4,
look the route up by `target` in decision 2's registry, and call the same
adapter. There is no second implementation to keep in step.

**At the executor seam the handler runs inside the delivery's
transaction, under the execution's lock.** Two rules follow, and both are
this record's.

A route called there must **only hand off durably**. A job inserted on the
host's own repo from the calling process joins that transaction, which
makes a transactional outbox the natural adapter shape and closes
ADR-0003 section 2's does-not-un-fire window: a rollback takes the job row
with it, so nothing was handed off for an execution change that never
committed.

A route called there must **never call `StatifierRouter.route/3`,
`StatifierPersistence.Executions.step/5`, or any other door of the sending
execution from inside `execute/2`**. A nested step would run from the
position the outer step has not written yet and would then be overwritten
by it. No reentrancy guard exists today: this record forbids the call, and
a test on the handler pins the refusal. That test is owed by the handler's
own bead and is not part of this record.

On the process-less shape the handler owns delayed sends and their
`<cancel>` **itself**, because no session holds anything across a resume:
those holds are the live session's own state and are not part of
`Statifier.Position`, and this package resumes on every delivery.

**Only the process-less shape writes the durable queue.** On the
send-processor shape the live session holds its own timers, and this
record leaves them where they are; the scope named for that shape below
exists so the key is DEFINED on both shapes, not because a live session
also writes rows. A host that does keep such a send across a resume - which
the engine's durable-timer record contemplates - keys it the same way, and
that is why the definition is given for both.

Concretely, on the process-less shape:

- A `%Statifier.Effect.SendDelayed{}` is recorded on the **host's own
  durable timer queue, keyed by `(scope, send_id)`** - `scope` being
  decision 4's scope half, `execution_id` at the executor seam and
  `session_id` on the send-processor shape. The send id alone is **not** a
  key: it is unique within one execution and not across a host, because a
  generated one is minted off a per-execution counter and an author-written
  one is reused verbatim, so `send_1` recurs in every execution on the host.
  This is st-ADR-0054's cancellation key, `{session scope, send_id}`, and
  that record says in terms that a package keying stored jobs on `send_id`
  alone "would be nonconformant with this record on day one". Decision 4's
  full composed key and `delay_ms` ride beside the row, the composed key as
  the dedup key: the cancellation key and the dedup key are two keys, not
  one. The handler schedules nothing in memory.
- A `%Statifier.Effect.Cancel{}` deletes **that scope's** rows for its
  `send_id`, and no other scope's. It may legitimately match more than one
  row - spec 6.3 cancels every delayed send under an id - and a cancel that
  matches nothing is a no-op, not an error. A cancel carries nothing that
  identifies the **route**: a `%Statifier.Effect.Cancel{}` has `c_index`,
  `owner`, the three counters and `ordinal`, but no `event`, `target` or
  `type`, so the queue row must carry the route name it was scheduled
  against.
- A cancel for a send already fired is a no-op, and a fire for a send
  already cancelled must not happen: the queue row is the single decision
  point, and both operations are writes against it.

### 6. Registered types reach a durable execution through the config surface, handed to `send_types:`

The host's processor becomes an engine-visible set through
`StatifierRouter.Config`, as the `Statifier.Send.Types` snapshot this
package hands to statifier_persistence's `send_types:` option.

That snapshot is **not** derived from decision 2's registry, and cannot be:
a types snapshot maps a **type string** to a processor module
(`Statifier.Send.Types.from_send_types/1` takes a `%{String.t() =>
module()}`), while decision 2's registry maps a **route name** to an
adapter, and this record's own example puts both of its routes under one
type. No type string is recoverable from that map. The type strings come
from decision 5's handler module and the type or types the host registers
it under; decision 2's registry is what the handler consults **after** a
send of such a type arrives, to find the adapter for its `target`.

Two facts govern how it is handed over, both from that option's own
typedoc on `StatifierPersistence.Executions`. On `step/5` the snapshot is
stamped onto the loaded position, unconditionally, on every step. On
`create/4` it must travel **inside `initialize:`**, because
`Statifier.MachineState.new/2` is the one writer of the `_ioprocessors`
entry each registered type gets and
`Statifier.MachineState.put_send_types/2` does not rewrite it. A
top-level `send_types:` on `create/4` type-checks and is ignored, and the
execution then lacks the host's types for its whole life.

The carrier for it is on `main` as this record is written:
`StatifierRouter.Config`'s `:persistence_options`, a keyword list over
`:routes`, `:invoke_types` and `:send_types`, carried onto every create and
every step of every delivery, with the create-side placement inside
`initialize:` that the paragraph above requires.

**`:routes` there is not this record's route.** It is
`Statifier.Send.Routes`, the engine's caller-declared, point-in-time claim
about which `<send>` routes are live - reachable session ids, whether a
parent exists, live invoke ids. It has nothing to do with the named
outbound destinations this record calls routes, and the two never meet: a
route of this record's rides in `target` under a registered `type`, which
the engine does not resolve at all. Where the ambiguity would bite, this
record says **route name** for its own noun.

What is **not** on `main` yet is decision 2's registry - route name to
adapter - together with the handler of decision 5 and the type strings it
is registered under, which are what a `Statifier.Send.Types` snapshot is
built from. That is the dependency this record names: the route-registry
bead adds both and hands the snapshot through `:persistence_options`, and
this record's foot takes a dated Note citing that surface's own record when
it lands.

### 7. A route the host has not registered

At **publish time** the check is this package's to build. The engine's
pre-start check is `Statifier.Send.Types.unsupported_sends/2`, and it sees
unregistered **types** only - a route **name** in `target` is opaque to
it. So this package owes a helper that reads a document's sends and lists
the route names the host's registry lacks. It is a later bead; this record
fixes only that the check belongs here and is pure, like the engine's.

At **run time** the adapter lookup misses, and the handler:

1. records a refusal on the routing ledger (ADR-0004 section 4), and
2. reports the miss the way the shape allows - `Statifier.Session.failed_send/3`
   on a live session; on the process-less shape by returning
   `{:error, reason}` from `execute/2`.

That return **does not roll the step back**, and that is deliberate. An
executor failure is deferred, re-entered as `error.communication` by
decision 3's path, and the execution is written anyway: the persist tail
executes, re-enters, then writes. The chart hears that its send did not
go; the step it just took stands. The alternative - rolling the delivery
back on a registry miss - would replay the whole event against an
unchanged registry forever.

### 8. Out of this record

No concrete adapter. No batching. No route that answers with data. No live
mode: this package is driven process-less, and the send-processor shape is
served because the same handler serves it, not because this package starts
sessions.

### Open triggers, named and not decided here

**A state that exists only to wait for one answer is an `<invoke>`, not a
route.** A route is the wrong shape for it: an invoke has the
cancel-on-exit and stale-answer semantics that waiting needs, and a route
has neither. The router-hosted invoke answer path is **unbuilt**: this
package hosts through `StatifierPersistence.Executions.create/4` and
`step/5`, carrying `:executor` and `Config`'s `:persistence_options` -
`:routes`, `:invoke_types` and `:send_types` - and **no driver-side invoke
door**. `:invoke_types` is the option a reader chasing this trigger checks
first, and it is not the missing piece: it declares the invoke types a
deployment implements **beyond the built-in handler**, and a chart may use
the built-in spellings with nothing in the snapshot at all. What it does
not do is carry a child's answer back. What is missing is a door, and that
package's driver-side invoke doors are outside the caller's-transaction
contract this package's ADR-0003 section 1 depends on.

ADR-0007, `docs/adr/0007-the-source-invoke.md`, specifies the other half of
`<invoke>` in this package - the source invoke, where an invocation's
lifetime is a subscription's - and reaches the same conclusion about this
one from its own side: it too declares the router-hosted invoke answer path
unbuilt, for the same reason, and designs nothing for it either. A reader
following this trigger should read that record beside this one.

This record names the trigger and designs nothing for it.

Three further questions are open for the operator and are recorded here so
a later reader does not mistake this record's silence for an answer. Each
would force a change to **this package** rather than to an adapter: a write
that needs cancel-on-exit and stale-answer discard, which is invoke
semantics and so needs a packaged invoke answer door; many concurrent
writes per execution with no way to thread a request id back, which is a
correlation table rather than decision 3's convention; and a permanent
failure that must reach the chart with nowhere to bind it, which is a
post-commit send-failure door for durable executions. This record answers
none of the three.

### The example: the impression-and-click join's outbound half

The join chart holds an impression, waits for its click, and on the join
writes one record and acknowledges. Its outbound half is two sends:

    <send type="myapp:sink" target="joined_records" event="joined">
      <param name="impression_id" expr="impression_id"/>
      <param name="click_id" expr="click_id"/>
    </send>

    <send type="myapp:sink" target="dead_letter" event="orphaned"/>

Both name the same processor type and differ only in the route. The host
registers `joined_records` and `dead_letter` once, per decision 2; a
staging scope points `joined_records` at a different sink and cannot make
a third route appear. The handler composes each send's key by decision 4 -
the effect's identity plus `execution_id` at the executor seam - so a
delivery that rolled back and was redriven hands the adapter the same key
and the adapter writes one record. Neither send answers: the acknowledgement
the join waits for, if there is one, arrives as an inbound event through a
binding.

### Enumeration is a test's, not this record's

This record states rules. Which sends in a given chart reach which
adapter, and which route names a document uses, are enumerated by the
tests that land with the handler and the publish-time helper of decision
7, against the chart in front of them. This record names no list of call
sites and claims no completeness over the package.

## Consequences

**An adapter must be idempotent, and the record says on what.** Decision
4's key is composed and handed over, so "be idempotent" is actionable
rather than advisory. The create-rollback limit is stated where an adapter
author will read it, rather than discovered in production.

**The transaction pays for the outbox and charges for slowness.**
Decision 5 makes durable hand-off the only thing a route may do at the
executor seam. The reward is that a job inserted on the host repo joins
the delivery transaction, so the outbox is free and ADR-0003 section 2's
does-not-un-fire window closes for adapters that take it. The price is
that the execution's lock and a pooled connection are held for the length
of the hand-off, so a slow adapter extends every other delivery's wait
for that execution, and an adapter that calls out over the network at
that seam is the shape this record exists to steer away from.

**A request and its answer are two deliveries, not one call.** Decision
3 sends the result back inbound through a binding, so a chart that wants
an answer writes the send, a binding for the result, and its own timeout
as a delayed self-send. That is more to author than a blocking call would
be, and it is what keeps a durable execution from holding anything open
across a resume. A state whose whole purpose is that wait wants an
`<invoke>`, which the open triggers above name as unbuilt here.

**The chart's outbound vocabulary is two attributes.** An author writes a
type and a route name. Repointing a route, swapping a sink, or splitting
one sink into two is host configuration, and no document is edited for it.

**The registry is not a per-execution capability.** Because a scope
overrides configuration and never existence, a chart cannot be written to
work in one scope and fail in another for want of a route. It fails the
same way everywhere, at decision 7's publish-time check.

**The failure path stays open.** Decision 3 keeps `error.communication`
reachable, so a chart can transition on a send that did not go. An adapter
that swallows its own errors and returns `:ok` removes that transition
from every chart on that route; this record makes that a stated
consequence rather than a surprise.

**A delayed send needs a durable queue before it needs an adapter.**
Decision 5 makes the timer queue a host obligation on the process-less
shape. A host with no such queue cannot serve a delayed send on a route at
all, and that is the honest reading rather than a silent drop after a
resume.

## Note (2026-09-21, sr-5em): the surface decision 6 named, as it landed

A Note, not an amendment: it decides nothing and changes no decision.
Decision 6's last paragraph named the route-registry bead as the
dependency that would add decision 2's registry, decision 5's handler and
the type strings it is registered under, and said this record's foot would
take a dated Note citing that surface when it lands. This is that Note.
Every module named here lands in the same commit as this Note.

- **The registry is `:route_adapters`, not `:routes`.** Decision 2 did not
  name the field, and decision 6 ruled what `:routes` means *there*:
  inside `:persistence_options`, which is one field of
  `%StatifierRouter.Config{}` and whose keys are `:routes`,
  `:invoke_types` and `:send_types`. The `:routes` key there is the
  engine's `Statifier.Send.Routes`. Spelling the registry `:routes` as
  well would have put that one name on two surfaces of a single
  configuration and re-opened exactly the ambiguity decision 6 closed, so
  the registry is spelled `:route_adapters`, a map from route name to
  `{module, config}`.
  `StatifierRouter.Config.route/3` resolves a name in a scope, applying
  `:route_overrides` over the registered configuration.

- **The adapter behaviour is `StatifierRouter.Route`, and it is one-way.**
  Its one callback answers `:ok` or `{:error, term()}` and returns no data,
  as decision 3 requires. It is handed decision 4's composed key as
  `t:StatifierRouter.Route.idempotency_key/0`: the scope half, where in the
  step the send sat, and the ordinal.

- **The handler is `StatifierRouter.SendHandler`, and it serves both
  shapes from one module, as decision 5 requires.** On the send-processor
  shape it respects `Statifier.Send.Processor`'s split (statifier 2.6.0):
  `deliver/3` composes decision 4's key and returns one
  `{:handler, module, payload}` instruction carrying it, `cancel/2`
  returns an instruction carrying the cancel effect and the scope and no
  key at all - a cancel is keyed on `(scope, send_id)` and carries
  nothing that identifies a route - and the adapter is reached from
  `perform/2`, the impure half. Decision 5's sentence that both entry
  points "call the same adapter" holds in substance; a handler that called
  an adapter from `deliver/3` would depart from that behaviour's
  documented purity.

- **The type string reaches the engine through `:send_type`.** Decision 6
  ruled that the snapshot cannot be derived from the registry.
  `StatifierRouter.Config.new/1` builds it from the one type string the
  host gives and the handler module, and a configuration that also
  declares `:send_types` itself is refused rather than one of the two
  silently winning.

- **The durable timer queue is the host's, and this package states its
  shape.** Decision 5 makes the queue a host obligation: it is "the
  host's own durable timer queue", and a host with no such queue "cannot
  serve a delayed send on a route at all". So the queue is
  `StatifierRouter.TimerQueue`, a behaviour a host registers rather than
  a table this package adds.
  `c:StatifierRouter.TimerQueue.cancel/3` takes the scope and the send id
  separately, which is st-ADR-0054's cancellation key; decision 4's
  composed key rides beside the row as the dedup key.

- **Section 7's routing-ledger row is not built, and the reported miss
  is.** An unregistered route misses, the miss is answered as an error,
  and the step still commits, all as section 7 states. The row itself is
  not written: the ledger's `binding_id` and `message_id` are both
  `NOT NULL` (`StatifierRouter.Migrations.V01`), an outbound route refusal
  has neither a binding nor an inbound message, and ADR-0004 section 4
  fixes the `outcome` column to that record's inbound vocabulary, which
  has no word for a send refusal. ADR-0006 solved that problem for its own
  case, and its section 6 scopes those outcomes to execution-to-execution
  sends. Minting a word or widening that vocabulary is record surface, so
  it is left for a ruling. `StatifierRouter.SendHandler`'s own
  documentation says the same thing where an implementer will read it.

- **This record and `Statifier.Send.Processor` disagree about a delayed
  send on the send-processor shape, and this Note only records it.**
  Decision 5 says the live session holds its own timers for a
  registered-type delayed send. That behaviour's moduledoc (statifier
  2.6.0) says the session schedules nothing and the processor owns the
  delay. Decision 5's other sentence - that only the process-less shape
  writes the durable queue - is what the handler was built to, so on the
  send-processor shape it writes no row and holds no timer, and answers a
  delayed send with an error rather than dropping it. Which of the two
  statements governs is not decided here.

## Note (2026-09-21, sr-p6u): section 7's routing-ledger row, as ruled and as it landed

A Note, not an amendment: it decides nothing and changes no decision. The
Note above it says section 7's routing-ledger row "is not built" and that
minting or widening a vocabulary for it was left for a ruling. The ruling
was taken on 2026-09-21, the row is built, and that bullet is
superseded by this Note. Everything else that Note records still holds.

**What was ruled.** That the row extends ADR-0006, section 6's send
convention rather than opening a parallel one. ADR-0006's own foot Note
of the same date carries the vocabulary half; this one records what
section 7 now has.

**The row.** `binding_id` is the reserved name `execution`, the one
ADR-0006, section 1 reserves and its consequences read as the mark of an
outbound send; `message_id` is decision 4's composed key, written out as
a slash-joined string and never parsed back; `outcome` is `send_refused`;
`reason` is `route`, the one word ADR-0006's Note adds for a target that
names no registered route; `key` and `execution_id` are empty, as they
are for every refusal discovered before a target is resolved. `scope` is
the host's partition, read from the sending execution's address row.

**A sender with no address row is reported and not recorded.** The
ledger's `scope` is `NOT NULL` (`StatifierRouter.Migrations.V01.up/1`),
and a sender that has no address row has no scope to write there. That is
the gap ADR-0006, section 6 already names for `unaddressed_sender`, and a
route refusal falls in it for the same reason rather than a new one.

What is looked up is the scope half of decision 4's composed key and
nothing else: `StatifierRouter.Addresses.by_execution/2` is asked for
that value's address row, and a scope half that names one is recorded
while a scope half that names none is reported only. The shape the
refusal arrived on does not decide it. On the send-processor shape the
scope half is the sender's session id, and whether that names an address
row is the host's arrangement rather than a property of this package:
ADR-0006, section 4 holds that at this package's seam the sender's
session id is its execution id, so a host that keeps the two the same is
recorded on that shape as well.

**The report is unchanged, and it is what section 7 puts first.** The
handler still answers `{:error, {:unregistered_route, name}}` on both
shapes, the step the sender took still commits, and the row records that
the sender was told rather than standing in for telling it - which is the
rule ADR-0006, section 3 states for its own refusals.

**A ledger insert that fails does not take the sender's step down, and
the bracket that holds that open is not an absolute.** The write happens
at the executor seam, inside the sending execution's own transaction,
where any failed statement leaves that transaction aborted whether or not
the caller handles the error. So the insert is bracketed in a SQL
savepoint of its own and rolls back to it on failure, which is what
`StatifierRouter.Delivery.deliver_event/4` does for the same seam and for
the same reason. An insert that fails is rolled back and the miss is
still reported.

What the bracket does not cover is the savepoint statements themselves.
Only the insert is guarded, so a release that raises after a successful
insert cannot become a rollback of the row just written and its own
failure is swallowed; but a connection that has gone away raises out of
the savepoint statements, and that raise stands and reaches the sender.
A bracket cannot settle a transaction it can no longer speak to. What it
buys is narrower than an absolute and is the thing section 7 needs: a
ledger row this package could not write is not itself what takes the
sender's step down.

**Where the code is.** `StatifierRouter.SendHandler`, whose moduledoc
section on the unregistered route says the same thing where an
implementer will read it, and whose own tests pin the row's columns and
the committed step together. This record stays at proposed.

## Amendment (2026-09-22, sr-a14): who owns a delayed send's timer on the send-processor shape

Status: accepted

Decision 5 says, under `Only the process-less shape writes the durable
queue.`, that on the send-processor shape the live session holds its own
timers. The engine decides otherwise, and it is the engine the code runs
against. `Statifier.Send.Processor`'s moduledoc, at statifier 2.6.0
(`deps/statifier/lib/statifier/send/processor.ex`), states: "**A delayed
send is the processor's timer.** For a `%Statifier.Effect.SendDelayed{}`
the session schedules nothing: the processor owns the delay, and spec
6.2's discard at termination is its fire-time check (ADR-0054 decision
4)."

- **The processor owns a registered-type delayed send's timer on both
  host shapes.** Decision 5's sentence that the live session holds its own
  timers is superseded for registered types. A live session schedules
  nothing for such a send, so there is no timer of the session's for this
  record to leave where it is.

- **One queue, one key, on both shapes.**
  `StatifierRouter.SendHandler.perform/2` - the impure half of the
  `Statifier.Send.Processor` callbacks - records the delayed send on the
  same `StatifierRouter.TimerQueue` the executor seam reaches through
  `handle_effect/3`, under decision 4's composed key. The cancellation key
  is unchanged: `(scope, send_id)`, the scope half being `session_id` on
  this shape.

- **The code half is bead `sr-4hw`.** `perform/2` answers a delayed send
  with an error today, which is what the sr-5em Note of 2026-09-21 records
  in its last bullet: on the send-processor shape the handler "writes no
  row and holds no timer, and answers a delayed send with an error rather
  than dropping it". This Amendment decides what shall be done; that bead
  does it. A record may lead the code it governs.

## Note (2026-09-22, sr-a14): accepted

A Note, not an amendment: it decides nothing and changes no decision above
it. The status on line 3 moved from `proposed` to `accepted` on the
operator's word of 2026-09-22, taken after statifier_router 0.2.0 was
published. Nothing else above this foot was edited.

Every claim this record makes about the package's own code was verified by
anchor at `251abb7`, the 0.2.0 release commit. Each decision's surface is
in the tree: the registry and its scope overrides on
`StatifierRouter.Config` (`:route_adapters`, `:route_overrides`, resolved
by `StatifierRouter.Config.route/3`); the one-way adapter contract
(`c:StatifierRouter.Route.deliver/3`, answering `:ok | {:error, term()}`);
the composed key (`t:StatifierRouter.Route.idempotency_key/0`, the scope
half, the step position and the ordinal); the one handler serving both
shapes (`StatifierRouter.SendHandler`, `handle_effect/3` at the executor
seam and `deliver/3`, `cancel/2`, `perform/2` on the send-processor
shape); the snapshot built from the single type string
(`StatifierRouter.Config.new/1`, which refuses a configuration declaring
`:send_types` of its own); the host-registered timer queue
(`c:StatifierRouter.TimerQueue.cancel/3`, taking the scope and the send id
separately); and the unregistered-route miss, reported as
`{:error, {:unregistered_route, name}}` with its ledger row written under
its own savepoint. The ledger's `binding_id`, `message_id` and `scope` are
`NOT NULL` in `StatifierRouter.Migrations.V01.up/1`, as the two Notes
above state.

**Three sentences of this record are named here rather than edited**, and
the three are these.

**One names this record's own status.** The Note above the Amendment ends,
under its heading `Where the code is.`, with the sentence `This record
stays at proposed.` It is not edited or removed: this Note names it and
records that it is superseded by the flip, which is how this repository
amends a record by addition.

**One no longer holds, and the Amendment above names the change.**
Decision 5's sentence that on the send-processor shape the live session
holds its own timers is contradicted by `Statifier.Send.Processor` at
statifier 2.6.0, the version this package pins. Under this repository's
flip standard a claim that no longer holds stops the flip unless a later
dated record names the change; the Amendment of 2026-09-22 above is that
record, so decision 5 is left as written and the Amendment governs.

**One is time-stamped and is now stale.** The subsection `The records this
one reads` says those engine and persistence surfaces are not in this
package's dependency tree, and names the constraints `~> 2.5` and
`~> 0.12.0`. That statement was true when it was written and is no longer:
`mix.exs` carries `~> 2.6` and `~> 0.13` and `mix.lock` resolves statifier
2.6.0 and statifier_persistence 0.13.0. ADR-0006, a later dated record in
this directory, names that same change under its own `What this record was
written against.` heading. The paragraph is left as written, being a dated
account of what the record was read against rather than a decision.

The status cell for this record in `docs/adr/README.md` is flipped by a
separate bead after all seven records; the index lags by design until then.

## Note (2026-09-22, sr-3qr): the Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The `Status:` line of the `## Amendment (2026-09-22,
sr-a14)` moved from `proposed` to `accepted` on the operator's word of
2026-09-22, in session. The record's own status on line 3 was already
`accepted` and was not touched, and the record's row in
`docs/adr/README.md` carries that status rather than the Amendment's, so
it does not move.

Every claim the Amendment makes was re-verified by anchor at `533b442`,
the commit this flip was cut from, and each holds:

- The sentence the Amendment quotes is verbatim in
  `Statifier.Send.Processor`'s moduledoc at statifier 2.6.0, the version
  `mix.lock` resolves.
- `StatifierRouter.SendHandler.perform/2` carries the
  `Statifier.Send.Processor` `@impl`, and the executor seam reaches
  `StatifierRouter.TimerQueue` through
  `StatifierRouter.SendHandler.handle_effect/3`. The cancellation key is
  `c:StatifierRouter.TimerQueue.cancel/3`'s scope and send id, and the
  scope half on the send-processor shape is the `session_id` that
  `StatifierRouter.SendHandler.cancel/2` reads from its context.
- `perform/2` answers a delayed send with
  `{:error, {:delayed_send_unsupported, send_id}}` today, which is what
  the Note of 2026-09-21 above records. That is not a stale claim: the
  Amendment decides what shall be done, and bead `sr-4hw`, open in this
  repository's tracker, is the code half.

With the flip, decision 5's sentence that on the send-processor shape the
live session holds its own timers is superseded for registered types, as
the Amendment says. Decision 5 is left as written; the Amendment governs.

## Note (2026-09-23, sr-d2u): which writes a caller's transaction can lose, audited

A Note, not an amendment: it decides nothing new. ADR-0003's Amendment of
the same date carries the one decision the audit needed; everything else
below is a write brought under the bracket the sr-p6u Note above
describes, or a path recorded as safe with its reason.

**The trap.** A `c:Ecto.Repo.transaction/2` called inside another
transaction gets no savepoint, whatever mode it asks for: db_connection
answers a nested transaction with `def transaction(%DBConnection{conn_mode:
:transaction} = conn, fun, _opts)` in `DBConnection`, at db_connection
2.10.2, the version `mix.lock` resolves, and the options are dropped. A
`c:Ecto.Repo.rollback/1` inside such a transaction, or any statement that
fails there, loses the enclosing transaction, even when the caller is
handed a well-formed `{:error, reason}`. The remedy this package uses is
the one the sr-p6u Note describes: an explicit `SAVEPOINT` before the
work, `RELEASE SAVEPOINT` on success, `ROLLBACK TO SAVEPOINT` on a handled
error, and the reason answered as an ordinary return, the savepoint's
name minted from `System.unique_integer/1`.

**The rule the audit applies.** A path that may run inside a caller's
transaction is safe when every failure in it either is settled at a
savepoint of its own and answered as a value, or raises and reaches the
caller unrescued, so that nothing answers over a transaction already
lost. A raise is left a raise: a host callback reached from the executor
seam must not raise, and one that does loses the sending step's
transaction and propagates. A path is a hit when it calls
`c:Ecto.Repo.rollback/1`, or answers a value after a failed statement,
inside work a caller's transaction encloses.

**This package's paths, read at `bfcc84d`.**

| Path | Can run inside | Verdict |
|---|---|---|
| `StatifierRouter.Delivery.deliver/4`, the door `StatifierRouter.route/3` and `StatifierRouter.Webhook.handle/3` reach | a host's own transaction | fixed: it called `c:Ecto.Repo.rollback/1`; it now settles at a savepoint (ADR-0003, the Amendment of 2026-09-23) |
| `StatifierRouter.Delivery.deliver_event/4` | the sending step's transaction | safe: settled at a savepoint of its own |
| the execution-target refusal row, `refused/6` in `StatifierRouter.SendHandler` | the sending step's transaction | fixed: it was a bare insert; it now takes the unregistered route row's bracket, so a row that cannot be written does not take the step down, as ADR-0006, section 3 has the step stand |
| the unregistered route row, `insert_refusal/4` in `StatifierRouter.SendHandler` | the sending step's transaction; the send-processor shape | safe: bracketed, as the sr-p6u Note above records |
| the sender's address read ahead of either refusal row, `StatifierRouter.Addresses.by_execution/2` | the sending step's transaction | safe: a failed read raises unrescued; it sits outside the bracket, and whether it moves inside is bead `sr-nfl`'s |
| every write inside a delivery - `StatifierRouter.Dedupe.claim/4`, the address insert, the terminal stamp, the ledger row - and `route/3`'s `key_refused` row | a host's own transaction | safe: nothing rescues a failed statement, which raises out of `route/3` (ADR-0003, section 1) |
| `StatifierRouter.subscribe/3` and `StatifierRouter.cancel/2`, and `StatifierRouter.SourceInvoke`'s `start/3` and `cancel/3` that call them | a host's invoke handler at the executor seam | safe: no rollback; every refusal is answered before any write, and a failed statement raises |
| `StatifierRouter.Addresses.reap/2` and `StatifierRouter.Dedupe.reap/2` | wherever the host schedules them | safe: no rollback; a failed statement raises |
| `StatifierRouter.PinSource.count/2` | `StatifierPersistence.Executions.retire_chart/4` | safe here: a failed read raises, which is how a pin source refuses; what the caller does with that raise is statifier_persistence's, below |
| a route adapter's `c:StatifierRouter.Route.deliver/3` and a timer queue's `c:StatifierRouter.TimerQueue.schedule/2` and `c:StatifierRouter.TimerQueue.cancel/3` | the sending step's transaction | the host's: the rule above binds the host's code, and this package cannot enforce it |

**statifier_persistence.** The transaction most of this nests inside is
`StatifierPersistence.Executions`' private `serialized/5`, and what that
package says of the trap belongs in its own records. Read at its
`af0cb5c`, its `lib/` calls no `c:Ecto.Repo.rollback/1` and asks for no
`mode: :savepoint`. Three places answer a value where the transaction
may already be lost:

- The Ecto adapter's `insert_execution/2`
  (`lib/statifier_persistence/storage/ecto.ex`, the
  `{:error, %Changeset{}} -> {:error, :execution_exists}` arm) answers
  a refusal after an `INSERT` its unique constraint failed, and Postgres
  has aborted the transaction over that statement. That package's own
  foot Note on its ADR-0004 records the same.
- The same adapter's private `insert_input/5` answers
  `{:error, {:adapter, :seq_conflict}}` from the same shape over the
  input log's unique `(execution_id, seq)` index.
- `StatifierPersistence.PinSource.collect/3` turns a pin source's raise
  - a failed read in this package's `count/2` among them - into an error
  return, so a retirement run inside a caller's transaction would answer
  over a transaction already lost.

The first two do not bite this package's deliveries. A delivery never
hands `create/4` an execution id that exists: it mints a fresh one, and
the address row's unique index settles a race before `create/4` is
reached (ADR-0003, section 3). A sequence conflict needs a second writer
of one execution's input log outside `step/5`'s lock. And were either
refusal to come back inside a delivery, the delivery's own savepoint was
opened before the failed `INSERT`, so rolling back to it returns the
enclosing transaction to a usable state before the reason is answered.
The third is statifier_persistence's to settle.

**statifier_oban.** Read at its `93bddde`, and changed by nothing here.
Every function in its `lib/` that reaches the database was found by
searching for `Oban.insert`, `Oban.cancel_all_jobs` and `Oban.Repo`:

| Function | Can run inside | Verdict |
|---|---|---|
| `StatifierOban.Timer.schedule/3` (`Oban.insert/2`) | the sending step's transaction | safe: no rollback; a failed statement raises |
| `StatifierOban.Timer.cancel/3` (`Oban.cancel_all_jobs/2`) | the sending step's transaction | safe: one update, no rollback |
| `StatifierOban.Invoke.Handler.perform_start/3` (`Oban.insert/2`, through its private `enqueue/4`) | the sending step's transaction, from a host's invoke handler | safe: no rollback; its refusals are answered before the insert |
| `StatifierOban.Invoke.Handler.perform_cancel/3` (`Oban.cancel_all_jobs/2`) | the sending step's transaction, from a host's invoke handler | safe: one update, no rollback |
| `StatifierOban.Invoke.FanOut.start/5` (`Oban.insert/2`, one per child) | the fan-out job's own perform, in `StatifierOban.Invoke.Worker` | not reached from a caller's transaction: Oban does not wrap a job's perform in one. Were it called inside one, the same verdict as `perform_start/3`: no rollback, and an `{:error, reason}` it answers is `Oban.insert/2`'s own, subject to the retry edge below |
| `StatifierOban.Invoke.FanOut.cancel_unstarted/3` (`Oban.cancel_all_jobs/2`) | wherever the host's settlement calls it, a step's transaction included | safe: one update, no rollback |
| `StatifierOban.Timer.pending_for/2` (`Oban.Repo.all/2`), and the pin source `use StatifierOban.Timer.PinSource` writes over it | `StatifierPersistence.Executions.retire_chart/4` | safe here: a failed read raises; statifier_persistence's `collect/3` is the answer over it, above |

At oban 2.23.1, the version its `mix.lock` resolves, the Basic engine
wraps an insert in `Oban.Repo.transaction/3` and a cancel is one update;
neither calls a rollback. One edge is recorded rather than judged: that
transaction retries `Postgrex.Error` and `DBConnection.ConnectionError`,
and Oban's own documentation of `Oban.Repo.transaction/3` warns that
inside an existing transaction a retry masks the real error and asks for
`retry: false` there; the Basic engine calls that transaction with no
options of its own. Under the default `on_exhausted: :raise` the error
still reaches the caller as a raise once the retries are spent; a host
that compiles Oban with `on_exhausted: :log` gets `{:error, exception}`
back instead, a value answered over a transaction already lost.

## Note (2026-09-23, sr-nfl): the refusal row's address read, and the composed key pinned whole

A Note, not an amendment: it decides nothing new. The sr-p6u Note above
decided that a ledger row this package could not write is not itself what
takes the sender's step down, and the sr-d2u audit Note above left one
question on that surface to this bead: whether the sender's address read
ahead of a refusal row moves inside the bracket. Each of the three
refusal rows is answered below.

**The unregistered route's read is inside the bracket.** The read is made
for the row and for nothing else, and a SELECT that fails inside the
sending step's transaction leaves that transaction aborted exactly as a
failed insert does. So `StatifierRouter.SendHandler`'s private
`record_refusal/4` now makes `StatifierRouter.Addresses.by_execution/2`
inside the savepoint the insert already had, and a read that fails rolls
back to it: no row is written, and the sender is still answered
`{:error, {:unregistered_route, name}}`. The row ADR-0006's delay
Amendment adds is written by the same function, so its read moved with
it. The sr-p6u Note's sentence "Only the insert is guarded" reads from
here on as "only the read and the insert are guarded": the release stays
outside, for the reason that sentence gives.

**The execution target's read stays outside, and needs no bracket.** The
private `to_execution/3` (read at `6370e75`) reads the sender's address
row before any refusal or delivery, because the scope it reads is the
send's own: ADR-0006, section 1 addresses the target inside it, and the
delivery through `StatifierRouter.Delivery.deliver_event/4` needs it as
much as a refusal row does. It is not a read made for a row, so there is
no row's savepoint for it to sit in. A read that fails there raises
unrescued and reaches the sender, which is what the audit Note's rule
above calls safe: nothing answers a value over a transaction already
lost.

**The execution-target refusal row was already bracketed.** The private
`refused/6` (read at `6370e75`) writes its row through the same bracket
as the unregistered route's, under a savepoint of its own prefix, as the
audit Note above records. That row's scope comes from the read the
paragraph above keeps outside, so no read sits inside its bracket.

**The composed key is pinned whole.** Section 4's key is written into a
refusal row's `message_id` by the private `message_id/1` (read at
`6370e75`): the scope half, the send's `send_id`, `macrostep`,
`microstep`, `round`, `c_index` and `owner`, then the ordinal. The test
"writes the composed key into the refusal row's message id in the
record's order", in `test/statifier_router/send_handler_test.exs`, gives
every component a value no other component carries and asserts the whole
string, so writing any two components in each other's place fails it.

## Amendment (2026-09-23, sr-ha3): the three values the handler keeps in the calling process

Status: accepted

`StatifierRouter.SendHandler` keeps three values in the calling process:
the configuration the send-processor callbacks serve (`put_config/1`),
the scope a delivery runs under (`put_delivery_scope/1`, which
`StatifierRouter.Delivery` sets for the length of a binding's delivery),
and the execution a route is running under (`sending_execution/0`). Read
at 3dcd54f, each had an edge. This Amendment decides all three, and the
code that implements it lands in the same change.

- **At the executor seam, a route some scope overrides is not resolved
  without a scope.** Decision 2 lets a scope override a route's
  configuration, and `StatifierRouter.Config.route/3` resolves a `nil`
  scope to the registered configuration unchanged (its own documentation,
  at 3dcd54f). The handler asked it with whatever scope the calling
  process held: none when it ran outside the process a delivery set it
  in, and none ever on the send-processor shape, which no delivery
  reaches. A send to a route some scope overrides therefore reached the
  registered configuration with no error, whichever scope it belonged to.
  At the executor seam (`handle_effect/3`, and the completion hook that
  shares its path) the handler now answers that send
  `{:error, {:no_delivery_scope, name}}`, for a delayed send as for a
  send. It is reported to the sender the way section 7 reports a miss,
  the sending step still commits, and no ledger row is written. A route
  no scope overrides resolves the same in every scope, so it still
  resolves with no scope in reach: refusing it would tell the chart a send
  failed that could only ever have gone one way.
  `StatifierRouter.Config.route/3` is unchanged, and so is a host firing a
  queued row through it, because the row carries the configuration
  resolved when it was scheduled (`StatifierRouter.TimerQueue`, "Firing a
  row").

- **On the send-processor shape the lookup is unchanged.** There
  `perform/2` still resolves a send, and a delayed send, to an overridden
  route's registered configuration, with no override applied and no
  error. A refusal there would reach no one: the engine discards
  `perform/2`'s return (`Statifier.Session`'s `perform_instruction/3`
  clause for a handler instruction, at statifier 2.7.0, the version
  `mix.lock` resolves), and this package gives a host no public way to
  name a scope on that shape (`put_delivery_scope/1` is `@doc false`). So
  a refusal would turn a send that goes somewhere into one that goes
  nowhere and is reported to nobody. A live session's send to an
  overridden route therefore still misses its scope's override; a public
  way to name a scope on that shape is a separate change.

- **What this narrows.** Decision 5 says both entry points "look the
  route up by `target` in decision 2's registry, and call the same
  adapter". After this Amendment the two shapes look the same name up in
  the same registry but can answer differently: with no scope in reach,
  the executor seam refuses a route some scope overrides, and the
  send-processor shape calls the registered adapter. The Consequences
  paragraph headed "The registry is not a per-execution capability" says
  a chart fails for want of a route the same way everywhere, at decision
  7's publish-time check. A send refused as `no_delivery_scope` fails at
  run time and only where no scope is in reach, which that check cannot
  see; it is a host arrangement that fails, not a missing route, and the
  sender hears it as `error.communication`.

- **The route mark covers the timer queue at the executor seam.**
  Decision 5 forbids a route called at the executor seam to call a door of
  the sending execution, and `StatifierRouter.Delivery.deliver/4` refuses
  while `sending_execution/0` names one. At 3dcd54f the mark was set only
  around the hand-off to a route, so the host's queue code, which
  `handle_effect/3` calls for a delayed send
  (`c:StatifierRouter.TimerQueue.schedule/2`) and for a cancel
  (`c:StatifierRouter.TimerQueue.cancel/3`) inside the same transaction
  and under the same lock, ran unmarked. A timer queue is not a route, but
  a nested step taken from it would be overwritten by the sender's step
  the same way. So `handle_effect/3` marks both calls as it marks a route:
  `sending_execution/0` names the execution while they run, and a
  `StatifierRouter.route/3` called from them is answered
  `{:error, {:reentrant_route, execution_id}}`. On the send-processor
  shape nothing is marked, for a queue call as for a route, because no
  delivery transaction is open there.

- **A missing configuration is not a failed send.** On the send-processor
  shape `perform/2` answers `{:error, {:no_config,
  StatifierRouter.SendHandler}}` when the process it runs in holds no
  configuration. The engine does not read that return
  (`Statifier.Session`'s `perform_instruction/3` clause for a handler
  instruction, at statifier 2.7.0, the version `mix.lock` resolves):
  reporting through `Statifier.Session.failed_send/3` is the host's, as
  the handler's moduledoc says. That reason says nothing about the send.
  Nothing was attempted in that process, and because `perform/2` may be
  called more than once for one send, an earlier call may already have
  delivered it. So a host does not report it to the chart as a failed
  send; it is the host's own configuration fault, answered by installing
  the configuration where `perform/2` runs. The return is unchanged, and
  every other `{:error, reason}` from `perform/2` is still a miss the host
  reports.

## Note (2026-09-23, sr-n7c): the Amendment of 2026-09-23 accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The `Status:` line of the `## Amendment (2026-09-23,
sr-ha3)` moved from `proposed` to `accepted` on the operator's word of
2026-09-23, in session, after its code shipped in statifier_router
0.4.0 (tag `v0.4.0`, at `fdf4071`). The record's own status on line 3
was already `accepted` and was not touched, and the record's row in
`docs/adr/README.md` carries that status rather than the Amendment's,
so it does not move. The two other Notes of 2026-09-23 above are not
part of this flip, and the Amendment rests on neither.

Every claim the Amendment makes was re-verified by anchor at `fdf4071`,
against `StatifierRouter.SendHandler` as it stands after the cure that
followed the Amendment's first draft, and each holds:

- At the executor seam, `handle_effect/3` and the completion hook's
  `deliver_to_route/5` resolve a route through the seam arm of the
  handler's private `resolve/3`, which answers
  `{:error, {:no_delivery_scope, name}}` when no scope is in reach and
  some scope overrides the route, for a send and a delayed send, and
  writes no ledger row; a route no scope overrides still resolves.
- `StatifierRouter.Config.route/3` still documents that a `nil` scope
  resolves the registered configuration unchanged, and
  `StatifierRouter.TimerQueue`'s "Firing a row" section is where it
  says a queued row carries its resolved configuration.
- On the send-processor shape `perform/2` resolves through the
  processor arm, which calls `StatifierRouter.Config.route/3` with no
  refusal; `put_delivery_scope/1` is `@doc false`; and
  `Statifier.Session`'s `perform_instruction/3` clause for a handler
  instruction, at statifier 2.7.0 (the version `mix.lock` resolves),
  calls `perform/2` and discards its return.
- The decision 5 sentence and the Consequences paragraph the Amendment
  names are quoted as they stand above.
- `handle_effect/3` wraps its delayed-send and cancel arms, which reach
  `c:StatifierRouter.TimerQueue.schedule/2` and
  `c:StatifierRouter.TimerQueue.cancel/3`, in the same mark as a route,
  so `sending_execution/0` names the execution while they run and
  `StatifierRouter.Delivery.deliver/4` answers
  `{:error, {:reentrant_route, execution_id}}`; `perform/2` marks
  nothing.
- `fetch_config/0` answers `{:error, {:no_config,
  StatifierRouter.SendHandler}}` when no configuration is installed,
  and the handler's moduledoc says that answer is not reported to the
  chart and that reporting a miss through
  `Statifier.Session.failed_send/3` is the host's.

## Amendment (2026-09-26, sr-mqzz): a host's own send types join the router's in one snapshot, through `:send_handlers`

Status: proposed

Decision 6 builds the `Statifier.Send.Types` snapshot "from decision 5's
handler module and the type or types the host registers it under", and
the sr-5em Note records how it landed: `StatifierRouter.Config.new/1`
builds it from the one `:send_type` and `StatifierRouter.SendHandler`,
and refuses a configuration that also declares `:send_types` itself.
Neither said what a host does when it serves send types of its own
beside the router's handler.

- **What the configuration does today** (read at `1e72588`). The only
  way to put a type into the snapshot is `:send_type`; a `:send_types`
  of the host's own inside `:persistence_options` is refused with
  `{:declared_send_types, send_type}` once `:send_type` is set
  (`StatifierRouter.Config`'s private `persistence_options/2`).
- **What that costs at run time.** Every create and every step of every
  delivery carries that snapshot (`StatifierRouter.Delivery`'s private
  `create_options/1` and `step_options/1`), so a host that serves a
  courier type of its own has to stamp a second snapshot in its
  `:on_create` and `:on_step` hooks over the router's.
- **What that costs at publish.** `StatifierRouter.Routes.unsupported_types/2`
  judges a chart against the snapshot on `:persistence_options`
  (its own `@doc`), and so does the `:unsupported_types` key of
  `StatifierRouter.Contracts.check/3`, which composes it unchanged
  (ADR-0008, decision 6). Every `<send>` of the host's own type is
  reported unsupported there, and the README told the host to judge its
  charts with `Statifier.Send.Types.unsupported_sends/2` itself.

The question left open was which of three answers holds: the
configuration gains a way to declare the extra types, `check/3` takes
the host's snapshot as an argument, or the README workaround stands.

### The decision

1. **The configuration gains a key.** `:send_handlers` is a map from a
   non-empty type string to the module that processes it, the shape
   `Statifier.Send.Types.from_send_types/1` takes. `new/1` merges it with
   `%{send_type => StatifierRouter.SendHandler}` and builds the one
   snapshot from the merged map. On a configuration with no `:send_type`
   the snapshot is built from `:send_handlers` alone. The key is named
   for its values, not `:send_types`, which already names the snapshot
   inside `:persistence_options` (decision 6 closed the like ambiguity
   over `:routes` by vocabulary, and this keeps to it).
2. **One snapshot, at run time and at publish.** The merged snapshot is
   the one on `:persistence_options`, so every delivery's create and
   step carry the host's types beside the router's, and
   `Routes.unsupported_types/2` and `check/3` judge a chart against the
   set it will be started with. A second argument to `check/3` is not
   taken: it would let the publish check judge a set the deliveries do
   not carry, which is the gap decision 6 exists to close.
3. **Refusals.** A value that is not a map of non-empty type strings to
   module names, or that names a built-in spelling (`"scxml"` or the
   SCXML processor's URI, which the engine classifies as built-in
   whatever the set holds), is refused with
   `{:invalid_value, :send_handlers, value}`. An entry under the
   configuration's own `:send_type` is refused with
   `{:declared_send_types, send_type}`, the refusal the sr-5em Note
   records for a `:send_types` of the host's own: that type names the
   router's handler and no other module. A non-empty `:send_handlers`
   beside a `:persistence_options` that carries `:send_types`, on a
   configuration with no `:send_type`, is refused with
   `{:exclusive_keys, :send_handlers, :send_types}` rather than one of
   the two silently winning. Only the shape is checked; `new/1` does not
   load the module.
4. **Absent is today.** Left out, or given as `nil` or `%{}`, the
   snapshot is built from `:send_type` alone, and a configuration with
   neither carries none, exactly as before this Amendment. The refusals
   above reach only a configuration that gives the key another value.
5. **The workaround stays valid and stops being needed.** A host whose
   hooks stamp their own snapshot keeps working, and its publish check
   still reads the configuration. The README section "Where the send
   types come from" now shows the key.
6. **The release.** The key is an addition to the configuration and
   ships in a minor release.

### The code

In the same change as this Amendment, citing it:
`StatifierRouter.Config` gains the `:send_handlers` option and struct
field (its moduledoc table and the paragraph after `:send_type`'s), its
private `send_handlers/2` checks the value, and its private
`persistence_options/3` and `send_types/2` build the merged snapshot.
`StatifierRouter.Routes.unsupported_types/2` is unchanged. The tests are
in `test/statifier_router/route_registry_test.exs`, in the describe block
`the host's own send types, :send_handlers (ADR-0005, the 2026-09-26
Amendment)`, and in `test/statifier_router/contracts_test.exs`, in the
describe block `check/3 with the host's own send types (ADR-0005, the
2026-09-26 Amendment)`, each with its sabotage note.

### The example

A depot's charts send parcel photos through the router's type and load
vans through a courier processor of the host's own:

    StatifierRouter.Config.new(
      repo: MyApp.Repo,
      store: store,
      executor: &MyApp.ParcelStepper.execute/2,
      resolver: MyApp.PublishedCharts,
      chart_resolver: &MyApp.PublishedCharts.chart/1,
      send_type: "myapp:router",
      send_handlers: %{"myapp:courier" => MyApp.Courier},
      route_adapters: %{"doorstep_photos" => {MyApp.OutboxRoute, %{}}}
    )

A `<send type="myapp:courier">` is supported by `check/3` under this
configuration and is reported under `:unsupported_types` without the
`:send_handlers` line.

### What this Amendment does not decide

- **Whether `StatifierRouter.SendHandler` may be named under a second
  type** in `:send_handlers`. It answers to `:send_type` alone, and the
  key does not change that.
- **Whether a `:send_handlers` module must implement
  `Statifier.Send.Processor`.** The engine's constructor does not ask
  it, and neither does this key.
