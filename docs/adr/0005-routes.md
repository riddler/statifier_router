# ADR-0005: Routes: the send type names the host's processor and the route name rides in `target`, a per-host registry whose scopes override a route's config and never its existence, one-way delivery whose only chart-visible outcome is a transport failure, an idempotency key the router composes from the effect's deterministic identity and the seam's context, one handler module for both host shapes, and the unregistered-route miss

Status: proposed

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
first, and it is not the missing piece: it declares which invoke types a
chart may use, not how a child's answer gets back. What is missing is a
door, and that package's driver-side invoke doors are outside the
caller's-transaction contract this package's ADR-0003 section 1 depends on. This record names that as an open trigger
and designs nothing for it.

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
