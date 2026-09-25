# ADR-0006: The execution target: a send whose params name a document and a key resolves through the address table, the scope is the sender's and never a param, delivery is the same one transaction a binding's delivery uses, the miss follows a `create` param that offers two of the three modes and is reported to the sender as well as recorded, the event is the engine's builder's, and a send to the sender's own address is refused

Status: accepted

## Context

ADR-0002, section 8 names three future readers of the address table:
sinks, timers and execution-to-execution sends, and says none of them is
in that release. This record opens the third of those three. An execution
that has finished its own work often has to hand something to another
execution: the impression-and-click join tells a placement counter that a
pair joined; a screen in one signup tells the enrolment that owns it that
it is done. Today the only way into a durable execution is an inbound
event through a binding, which means a host has to turn one execution's
output into a source event and route it back in.

What is already decided bounds the answer, and the bounds are unusually
tight.

- **The engine refuses an unregistered send type and hands a registered
  one to the host.** A `<send>` whose `type` resolves to a string the
  session was not started with raises `error.execution` and builds no
  effect; a registered one produces the ordinary send effect plus the
  event the library would have delivered (st-ADR-0069,
  `docs/adr/0069-host-registered-send-types.md` in statifier-ex,
  decisions 1, 3 and 4, read at statifier-ex 2105a44).
- **The engine names three things an opening record owes.** The record
  that deferred durable delivery between sessions listed the event
  carrier, the miss semantics and the identity story, so that the record
  firing on its trigger would not rediscover them (st-ADR-0055,
  `docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md` in
  statifier-ex, decision 3). Its trigger has since fired and been
  answered in general for every host processor; what is owed here is this
  package's answer to each.
- **This package's outbound sends already have a spelling, a return and
  a key.** ADR-0005 puts the host's registered processor in a send's
  `type` and a route name in its `target` (section 1), makes the route
  one-way with `error.communication` carrying the `sendid` as the one
  event it can cause in the sending execution (section 3), composes the
  idempotency key from the send effect's deterministic half and the
  shape's context (section 4), and puts both entry points in one handler
  module (section 5). This record reuses all four rather than inventing a
  second set.
- **An execution created under `always_new` has no address.** That mode
  writes no address row (ADR-0002, section 7), so such an execution has
  no `(scope, document, key)` and cannot be named by one.
  `StatifierRouter.Delivery`'s `by_mode` clause for `:always_new` says
  the same in code: it creates under a freshly minted id and passes no
  row.
- **The seam context carries no scope.** The executor seam hands the
  handler an execution id and a content hash. The scope rides with an
  inbound event, as a field of the event the host passes to `route/3`
  (ADR-0003, section 8), and there is no inbound event here.
- **The ledger's `scope` column is `NOT NULL`.**
  `StatifierRouter.Migrations.V01.up/1` adds `scope` to `routing_ledger`
  with `null: false`, so a fault discovered before this record has a
  scope in hand has no ledger row available to it. Section 6 is written
  around that.

**What this record was written against.** It was drafted on 2026-09-20
against a tree that still resolved statifier 2.5.0 and
statifier_persistence 0.12.0, and rebased the same day onto a main whose
`mix.exs` carries `~> 2.6` and `~> 0.13` and whose `mix.lock` resolves
statifier 2.6.0 and statifier_persistence 0.13.0. The sections below rest
on three engine surfaces, and all three are in that tree:
`Statifier.Send.Event.build/3` and `Statifier.Session.failed_send/3`
(statifier 2.6.0), and `StatifierPersistence.Executions`' documented
executor-failure re-entry (statifier_persistence 0.13.0). A fourth,
`Statifier.Interpreter.deliver_internal/5`, appears once in section 3,
inside that documentation's own words rather than as a claim of this
record's; it is public in statifier 2.6.0 too. Where a section below
rests on an implementation detail rather than on a documented surface, it
says so and names the version it was read at. The records
this one cites in statifier-ex were read at 2105a44. What is **not** in
the tree is anything that calls those surfaces: no module in this package
implements the engine's send-processor behaviour, and section 2 says
where that handler comes from.

## Decision

### 1. The spelling: the host's processor in `type`, the reserved name `execution` in `target`, the address in params

An execution-to-execution send is written with the host's registered
processor in `type` and the reserved name `execution` in `target`, which
is ADR-0005, section 1's spelling with one name reserved out of it:

    <send type="myapp:router" target="execution" event="pair.joined">
      <param name="document" expr="'placement_counter'"/>
      <param name="key" expr="placement"/>
      <param name="create" expr="'never'"/>
    </send>

`document` and `key` are required and each must resolve to a non-empty
string; `create` is optional and defaults to `if_absent`, ADR-0001,
section 1's default for a binding's `create`. **`execution` is a reserved
name**: a host registry that offers a route under it is refused when the
router's configuration is validated, so a chart that writes it always
means this record's target and never a host's transport.

**The scope is the sender's, never a param.** The router reads the
sending execution's own address row by its execution id and takes the
`scope` from it, so a chart can address only inside the scope it is
running in, and ADR-0002, section 2's partition holds without the author
being trusted to keep it. That read is the handler's first step, and
everything in sections 2, 3 and 6 assumes it has happened.

Two things that read relies on, said here rather than left to be derived:

- **One address row per execution is an invariant of the create path, not
  a constraint the schema enforces.** ADR-0002, section 1's unique index
  is on `(scope, document, key)`; the `execution_id` index
  `StatifierRouter.Migrations.V01.up/1` adds is not unique, and that
  module's own documentation says it exists so that the rows naming one
  execution are found without a scan. What keeps the count at one is that
  each create mints a fresh id and writes at most one row for it.
- **A sender with no address row has no scope and no key of its own.**
  That is exactly what `always_new` produces (ADR-0002, section 7), and
  such a send is a refusal (section 6).

### 2. Resolution and delivery are the ones this package already has

Resolution is the address table's `(scope, document, key)` lookup
(ADR-0002, section 1), and delivery is the same single transaction
ADR-0003, section 1 describes, in the same order: the dedupe row, the
address insert-or-lookup, `create/4` when the mode calls for one,
`step/5`, and the ledger row. An execution-to-execution send therefore
gets get-or-create, the unique index's race settlement, the dedupe row
and the ledger without a second write path to the address table.

**Who plays the binding on the ledger row.** The ledger row (ADR-0004,
section 4) takes the reserved name `execution` as its `binding_id`, the
same one name the chart wrote in `target`; a host binding whose `id` is
`execution` is refused for the same reason a host route under that name
is. Its `scope` is the sender's, its `key` the resolved `key` param, and
its `execution_id` the resolved target.

**What plays the message id, and why a retried step cannot deliver
twice.** The `message_id` is ADR-0005, section 4's idempotency key. That
record composes it, and this one inherits it rather than defining a
second: its effect half is the send effect's `send_id`, step counters,
`c_index`, `owner` and `ordinal`, and its scope half is the sender's
execution id at the executor seam or its session id on the send-processor
shape. Composing it is ADR-0005, section 5's one handler module's job at
both entry points. **That handler is not in `lib/` yet** - nothing in
this package composes a key today - and the bead that adds it is where
this record's code half lives.

Every component of that key's effect half is a counter or a static
content position stamped when the send was executed, so re-running the
sender's step after a crash composes a byte-identical key; the dedupe row
for `("execution", that key)` is then present and unexpired, and the
second delivery is a duplicate that writes its ledger row and nothing
else (ADR-0003, section 6). The dedupe row's horizon is ADR-0001, section
1's default, 259_200_000 milliseconds, since no binding supplies one
here.

**The one case where it does not hold, stated rather than papered over.**
If the sender itself was created inside a transaction that then rolled
back, the redelivery creates the sender again under a newly minted id
(ADR-0002, section 3 forbids deriving that id from anything stable), so
the scope half of the key differs and the second firing is new work. That
is the documented cost of stepping inside the transaction (ADR-0003,
section 2), and ADR-0005, section 4 states the same limit for a route.

### 3. The miss follows the `create` param, which offers two of the three modes, and the sender is told

| `create` | No row for the address | The row's execution is active | The row's execution is terminal |
|---|---|---|---|
| `if_absent` (default) | insert the row, `create/4`, `step/5`: created_and_delivered | `step/5`: delivered | stamp `terminal_seen_at` if empty, no step: dropped: finished |
| `never` | no row, no create, no step: dropped: no_execution | `step/5`: delivered | stamp `terminal_seen_at` if empty, no step: dropped: finished |

Those are ADR-0003, section 4's rows for the two modes, unchanged.
**`always_new` is not offered.** A send that names a document and a key
is asking for the execution that address holds; a mode that writes no
address row would create an execution the named key does not address, so
the next send with the same params would create another, and the chart's
key would mean nothing. A `create` param resolving to anything but
`if_absent` or `never` is a refusal (section 6).

**A miss is reported to the sender, and the ledger row records that it
was reported.** When the address does not resolve under `never`, and when
the target is terminal under either mode, the send did not reach an
execution. The router reports it the two ways ADR-0005, section 7 already
reports an unregistered route: on the process-less shape by returning
`{:error, reason}` from the handler's `execute/2`, which does not roll the
sender's step back and is re-entered as `error.communication` carrying the
send's `sendid` (ADR-0005, section 3's path); on a live session through
`Statifier.Session.failed_send/3` (statifier 2.6.0). That is what
st-ADR-0069, `docs/adr/0069-host-registered-send-types.md` in
statifier-ex, decision 5 requires of any processor that cannot deliver
while the sender still exists.

**The ledger row is written as well, and it is a record OF that report,
not a replacement for it.** The difference is the whole of this rule. The
row is how an operator finds, per scope and per key, which sends did not
land; the `error.communication` is how the chart finds out that its send
did not go. Neither stands in for the other, and a handler that wrote the
row without reporting would leave the chart believing the send landed.

**When the chart hears it differs by shape, and only one of the two is
this package's.** At the executor seam the `{:error, reason}` re-enters
the sending execution inside the same `step/5`, as its own wave, before
that step's position is written: `StatifierPersistence.Executions`'
documentation says executor failures on actionable effects re-enter the
chart as `error.communication` through
`Statifier.Interpreter.deliver_internal/5` and that re-entry is
single-wave per step (statifier_persistence 0.13.0). ADR-0005 attaches
"in the same step" to that arm alone, and this record does the same. On a
live session the report goes through `Statifier.Session.failed_send/3`,
which is a cast (statifier 2.6.0), so the write lands in a later message
and the chart does not hear inside the sending step; that record says
nothing about the live arm's timing and neither does this one beyond
that. **This package is driven process-less**, so the seam arm is the one
it actually drives; the live arm is served because ADR-0005, section 5's
one handler serves both shapes.

**Why the report rather than a row alone.** An earlier draft of this
record reported nothing under `never`, on the ground that an address that
does not resolve is an addressing outcome rather than a transport failure
and so falls outside C.1's `error.communication`. That distinction is
real, but st-ADR-0069 decision 5 is accepted upstream and draws no such
line: its only carve-out is a processor "whose route creates its target
on a miss (get-or-create)", which is `if_absent` and not `never`. A
record at proposed does not silently override an accepted one, and two
records disagreeing leaves a reader unable to tell which governs, so this
record conforms. The distinction is raised as a question for the engine
rather than decided here.

**Under `if_absent` there is no miss at all**, which is that carve-out
exactly: the target is created and stepped in the same transaction, so
nothing is reported and the ledger row is an ordinary
created_and_delivered.

**A chart that needs an answer still binds one back.** An
`error.communication` is a transport failure and not an answer (ADR-0005,
section 3). A receiver's result comes back as its own event, routed in
through an ordinary binding whose `key` program names the original
sender's key: a second, independent delivery with its own address, its
own dedupe row and its own ledger row.

### 4. The event carrier is the engine's builder, and the envelope params do not travel

The delivered event is built by `Statifier.Send.Event.build/3` (statifier
2.6.0) from the send effect and the sender's session id, which at this
package's seam is the sender's execution id. `name` is the send's `event`
and the rest of the stamps are the builder's. Two things are this
record's:

- **`origin` and `origintype`.** The router passes no `:origin`, so the
  builder's default stands and `origin` names the sender's execution
  (`#_scxml_<execution id>`), which survives a resume because a resumed
  session keeps its `_sessionid` (st-ADR-0069 decision 5, sender half).
  It passes `:origintype` as the type string the host registered its
  processor under, so a receiver that answers "via the Event I/O
  Processor specified in 'origintype'" reaches this processor rather than
  the engine's; that answer is a send of its own, addressed by its own
  params, and never a reply to this one.
- **The envelope params are consumed.** `document`, `key` and `create`
  name the envelope, not the message, and are removed from the delivered
  event's `data`. A chart that wants the key in the payload writes it
  again under another param name, so the receiver never has to know
  whether a field addressed it or was meant for it.

### 5. This package's answer to the three items the engine's record says an opening record owes

st-ADR-0055
(`docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md` in
statifier-ex), decision 3 names three; st-ADR-0069
(`docs/adr/0069-host-registered-send-types.md` in statifier-ex), decision
5 answers them in general for any host processor. This package's answers:

- **The event carrier** is that record's decision 4 builder,
  `Statifier.Send.Event.build/3`, called by this package with the
  sender's execution id and this record's `origintype` (section 4).
- **The miss semantics** are section 3's, and they are decision 5's
  unchanged: under `never` and for a terminal target the miss is reported
  to the sender as `error.communication` with the `sendid`, through
  ADR-0005, section 7's two shapes, and the committed ledger row records
  that report rather than standing in for it; under `if_absent` there is
  no miss, which is decision 5's get-or-create carve-out.
- **The identity story** is section 1's and section 4's: the target half
  is the host address `(scope, document, key)` resolved through
  ADR-0002's table, exactly the target half decision 5 describes, and the
  sender half is the sender's own execution id, which is stable across a
  resume and is what the builder's default `origin` names.

### 6. A send to the sender's own address is refused, and which refusals reach the ledger

The outcomes of an execution-to-execution send are this record's, not
ADR-0004, section 1's seven, which are scoped to one routing attempt per
binding. Five of ADR-0004's terms are reused verbatim for the states they
already name: delivered, created_and_delivered, duplicate, dropped:
no_execution and dropped: finished. `no_match` and `key_refused` have no
meaning here, because there is no `match` and no `key` program. One term
is added, `send_refused`.

**How an outcome is spelled.** These outcomes are not `route/3` tuples:
`route/3` routes an inbound event and this is a send. The handler's own
return is ADR-0005, section 3's `:ok | {:error, reason}`, and the outcome
word is what the ledger row's `outcome` column holds, spelled as in
ADR-0004, section 4 and in the paragraph above.

**`send_refused`'s reasons, and which of them can be recorded.** A
refusal is reported to the sender by section 3's two shapes in every
case. Whether it also reaches the ledger depends on one thing: the
ledger's `scope` is `NOT NULL`, and the scope is the sending execution's,
read from its address row as section 1's first step.

| Reason | Means | Ledger row |
|---|---|---|
| `unaddressed_sender` | the sending execution has no address row, so there is no scope | none: reported only |
| `document` | the `document` param is absent or is not a non-empty string | one row, `key` and `execution_id` empty |
| `key` | the `key` param is absent or is not a non-empty string | one row, `key` and `execution_id` empty |
| `create` | the `create` param resolves to neither `if_absent` nor `never` | one row, `key` set, `execution_id` empty |
| `self_address` | the resolved `(scope, document, key)` holds the sending execution's own id | one row, `key` and `execution_id` set |

The first is the only one discovered before the scope is in hand, and it
is the only one the schema cannot record. The other four are discovered
after it, so each writes one row and is reported. Nothing is left to
infer: a refusal with no ledger row is `unaddressed_sender` and nothing
else.

**Why a self-addressed send is refused rather than delivered.** `step/5`
would be asked for the lock the sender's own delivery already holds, and
a chart that means to send to itself has the engine's own `:self` route
for it.

**A cycle between two executions is the charts' business.** The router
detects none: A sending to B and B sending back to A is two sends, each
from a different sender, each advancing its own step counters and
ordinal, so each composes a different idempotency key and is genuinely
new work. What the dedupe key bounds is the other storm, the one the
router causes: a delivery that rolls back and is retried composes the
same key every time, so a crash-retry loop delivers once however often it
runs (section 2).

### The example: the impression-and-click join tells a placement counter

The join of ADR-0001's example finishes when an impression and its click
have both arrived. The impression binding projects `placement` into the
chart's data, so the join holds one. Its final state writes:

    <send type="myapp:router" target="execution" event="pair.joined">
      <param name="document" expr="'placement_counter'"/>
      <param name="key" expr="placement"/>
      <param name="placement_id" expr="placement"/>
    </send>

The sender is an execution of `impression_click_join` in the scope
`"7c1e"`, so the router reads its address row, takes the scope `"7c1e"`,
and resolves `("7c1e", "placement_counter", "home_top")`. No row exists
the first time, `create` defaults to `if_absent`, and the counter
execution is created on the chart the host's resolver names for
`("7c1e", "placement_counter")` and stepped with `pair.joined`, whose
data is `%{"placement_id" => "home_top"}`: the third param, the two
envelope params having been consumed. The ledger gains one row:
`binding_id` `execution`, `scope` `"7c1e"`, `key` `"home_top"`, outcome
created_and_delivered. The next join on the same placement resolves
through the row to the same counter and is a delivered. If the sender's
step is replayed after a crash, the idempotency key is unchanged, the
dedupe row is present, and the outcome is a duplicate with no second
step.

Had the send written `create` as `never` before any counter existed, the
outcome would be dropped: no_execution, the ledger would hold that row,
and the join would take `error.communication` with the send's `sendid`.
The join is a durable execution stepped at the executor seam, so it takes
it inside the same step, before that step's position is written, and a
transition armed on it fires in that step.

### Enumeration is a test's, not this record's

This record states rules. Which params a given chart writes, which
refusals a given misconfiguration produces, and that every path above
lands the outcome it names are enumerated by the execution-target tests
the code half adds, not claimed here over a live codebase.

## Consequences

- ADR-0002's third named future reader exists. The address table gains
  one more resolver beside delivery from a binding, and no second writer:
  an execution-to-execution send inserts and reads through the same
  get-or-create the delivery record owns.
- An `always_new` execution can neither be sent to nor send: with no
  address row it has no key to be addressed by (ADR-0002, section 7) and
  no scope to send from (section 1). A host that wants such an execution
  to send gives it an address by using another create mode.
- A chart can reach another execution without the host turning its output
  into a source event, and it still cannot reach outside its own scope,
  because the scope is read from the sender's row rather than written by
  the author.
- **Three of the ledger's columns are read differently now, and section
  4 of ADR-0004 is where a reader learns the old reading.** That section
  says `reason` is "empty otherwise", meaning for every outcome but
  key_refused; `key` is "empty for key_refused"; and `execution_id` is
  "empty for duplicate, key_refused and dropped: no_execution". Section
  6's refusal rows add to all three: `send_refused` puts a second
  outcome's reason in `reason`, leaves `key` empty for its `document` and
  `key` reasons, and leaves `execution_id` empty for its `document`, `key`
  and `create` reasons. No column's shape changes and no row already
  written means anything different. What changes is that an empty `key`
  or an empty `execution_id` no longer identifies the outcome on its own:
  a reader asks which outcome the row carries first, and section 6's
  table says what each refusal reason leaves empty.
- The ledger becomes the one place both directions are visible: an
  inbound delivery and an execution-to-execution send write rows of the
  same shape, and the reserved `execution` binding id is how they are
  told apart. One refusal is invisible there by construction, and section
  6 names it.
- **At the executor seam, which is the shape this package drives, a
  chart hears about a miss inside the step that sent.** The executor's
  `{:error, reason}` re-enters as `error.communication` in its own wave
  within the same `step/5`, before the position is written, and the step
  the sender took stands (`StatifierPersistence.Executions`'
  documentation, statifier_persistence 0.13.0). So a chart there can arm
  a transition on `error.communication` and have it fire in that step,
  and conforming to the upstream record costs it nothing it could
  otherwise have had. **On a live session it costs a step**:
  `Statifier.Session.failed_send/3` is a cast, so the chart hears in a
  later message and cannot act inside the sending step. The property
  belongs to the seam, not to the rule.
- The reserved name costs a host one name in two places: it may not
  register a route called `execution` and may not give a binding that
  `id`. Both refusals are configuration-time, so no chart discovers them
  at run time.
- This record leaves to later records and to the code half: the handler
  that composes ADR-0005, section 4's key and both entry points that call
  it, the configuration-time validation that refuses the reserved name,
  the encoding of `send_refused`'s reason in the ledger's `reason`
  column, and whether a send may address a document in a scope the host
  declares equivalent to the sender's, which this record simply does not
  allow.
- Whether an unresolved address is genuinely transport failure, or a
  third thing that C.1's `error.communication` was not written for, is
  left open for the engine to decide. This record conforms to the
  accepted answer and records the argument it set aside (section 3) so
  that the question survives the conforming.

## Note (2026-09-21, sr-p6u): `send_refused` names any send this package refuses, and `route` is its fifth reason

A Note, not an amendment: it decides nothing this record had not already
decided, and it changes no decision. What it records is a ruling taken on
2026-09-21 (RF062-R1) about a case section 6 had put outside itself.

**The case.** ADR-0005, section 7 has the handler record a run-time route
miss on the routing ledger. That row was not built when the route
registry landed, because the ledger's `binding_id` and `message_id` are
both `NOT NULL` (`StatifierRouter.Migrations.V01.up/1`), an outbound
route refusal has neither a binding nor an inbound message, and ADR-0004,
section 4 fixes the `outcome` column to that record's inbound vocabulary,
which has no word for a send refusal. This record had already solved that
problem for its own case in section 6.

**What was ruled.** That the route refusal takes section 6's convention
rather than a parallel one of its own. So:

- `send_refused` is read as the outcome of **any** send this package
  refuses, not only an execution-to-execution one. Section 6's opening
  sentence scopes that section's outcomes to an execution-to-execution
  send, and it is the vocabulary rather than the section that widens: the
  words, the reserved `binding_id` and the message id are shared, and
  every rule section 6 states about an execution-to-execution send still
  states it about that send alone.
- The reserved name `execution` is the `binding_id` of a route refusal's
  row too. That is the reading this record's consequences already give
  the reserved id: it is how an outbound send's row is told from an
  inbound delivery's, and a route refusal is outbound.
- The `message_id` is ADR-0005, section 4's composed key, the same one
  section 2 borrows for a delivered send.
- One reason is added under `send_refused`, in the shape section 6's four
  recordable reasons have - one lowercase word naming the thing at fault:

| Reason | Means | Ledger row |
|---|---|---|
| `route` | the send's `target` names no route the host registered (ADR-0005, section 7) | one row, `key` and `execution_id` empty |

  It is discovered before any target is resolved, so it leaves the two
  columns empty for the same reason `document` and `key` do.

**The scope is read the same way, and so is the gap.** Section 6's rule
that a refusal with no ledger row is `unaddressed_sender` is a rule about
an execution-to-execution send, and it is unchanged. The ledger's `scope`
is the host's partition (ADR-0004, section 4), so a route refusal reads
it from the sending execution's own address row exactly as section 1
does, and a sender with no address row is reported and not recorded.

The lookup is on the scope half of ADR-0005, section 4's composed key and
on nothing else - `StatifierRouter.Addresses.by_execution/2` is asked for
that value's address row - so whether a refusal is recorded turns on
whether that value names a row, not on which shape the send arrived on.
The send-processor shape is not exempt by construction: section 4 of this
record holds that at this package's seam the sender's session id is its
execution id, so a host that keeps the two the same finds the address row
on that shape too and its refusal is recorded. A host whose session ids
answer to no address row is in the gap above, for the reason the gap
names.

**What this Note does not do.** It adds no outcome word, widens no
handler return - an unregistered route still answers
`{:error, {:unregistered_route, name}}` - and leaves this record at
proposed. The code half is `StatifierRouter.SendHandler`, whose
documentation carries the same reading where an implementer will find it.

## Note (2026-09-22, sr-9gp): accepted

The status on line 3 reads `accepted`. The flip was made on the
operator's word of 2026-09-22, taken after statifier_router 0.2.0 was
published, and nothing above this Note changed but that one word.

**Where the claims were verified.** Every claim this record makes about
`lib/` was re-read by anchor at
`251abb7f8b71b673e0f59b0e2eb00dac08606a57`, the 0.2.0 release commit
tagged `v0.2.0`: the `:always_new` clause of `StatifierRouter.Delivery`'s
`by_mode`, which mints an id and passes no row; the `scope`,
`binding_id` and `message_id` columns declared `null: false` and the
non-unique `execution_id` index, all created by
`StatifierRouter.Migrations.V01.up/1`, whose own `@moduledoc` gives that
index the reason section 1 quotes; `StatifierRouter.Addresses.by_execution/2`;
the two configuration-time refusals `StatifierRouter.Config.new/1`
answers with, `{:reserved_route, name}` and `{:reserved_binding_id,
name}`, both taking the reserved name from
`StatifierRouter.SendHandler.execution_target/0`; the three envelope
params and the five refusal reasons carried by
`StatifierRouter.SendHandler`; and the unregistered-route return quoted
in the sr-p6u Note above, `{:error, {:unregistered_route, name}}`. The
dependency sentence above holds unchanged: `mix.exs` carries `~> 2.6`
and `~> 0.13`, and `mix.lock` resolves statifier 2.6.0 and
statifier_persistence 0.13.0.

**Two sentences are older than the tree, and this Note meets them
rather than editing them.** The Context's closing sentence says that no
module in this package implements the engine's send-processor
behaviour, and section 2 says in bold that the handler "is not in
`lib/` yet". The code half has since landed as
`StatifierRouter.SendHandler`, which the sr-p6u Note above already
names as this record's code half and which declares
`@behaviour Statifier.Send.Processor`. Both sentences are read as
describing the tree the record was drafted against, which the paragraph
they sit beside says plainly, and neither is reworded here.

**Two sentences speak of this record's own status, and both are met by
this Note rather than edited.** Section 3 argues that "a record at
proposed does not silently override an accepted one ... so this record
conforms" to st-ADR-0069, decision 5. That argument is unchanged by the
flip: the record conformed while it was proposed and conforms now, and
the question it set aside is still open for the engine, exactly as the
last consequence says. The sr-p6u Note above closes by saying it
"leaves this record at proposed"; that was true of that Note, which
decided nothing about the status, and this Note is what moves it.

The status column for this record in `docs/adr/README.md` still reads
`proposed`. That index is flipped once for all seven records by a
separate bead, so it lags this file by design until then.

## Amendment (2026-09-23, sr-73n): a delayed send to the execution target is refused by name, and `delay` is its reason

Status: accepted

Sections 1 to 6 describe a send the handler delivers at once. None of
them says what a **delayed** send to the reserved name means - a
`<send>` with a `delay` or a `delayexpr`, which reaches this package as
the engine's delayed-send effect rather than as a send.

- **The case.** The handler's delayed arm asked the route registry for
  the send's `target` before this Amendment
  (`StatifierRouter.SendHandler`'s `enqueue/4`, read at `3dcd54f`), and
  the registry can never hold the reserved name:
  `StatifierRouter.Config.new/1` refuses a route registered under it with
  `{:reserved_route, name}` (`route_adapters/1`, read at `3dcd54f`). So
  the sender was answered `{:error, {:unregistered_route, "execution"}}`
  and a `route` row was written. That reason reads as a host
  configuration error, a route the host forgot to register, when no host
  could have registered it and the truth is that the feature is not
  offered.
- **The decision.** A delayed send to the execution target is out of
  scope for now and is refused by name. It is neither delivered nor put
  on the host's timer queue. The handler answers
  `{:error, {:send_refused, :delay}}` on both shapes, before the route
  registry is asked, and the sender hears it the way section 3 reports
  every refusal.
- **One reason is added under `send_refused`**, in the shape section 6's
  reasons and the sr-p6u Note's `route` have:

| Reason | Means | Ledger row |
|---|---|---|
| `delay` | a delayed send names the reserved target | one row, `key` and `execution_id` empty, when the sender has an address row; none otherwise |

- **The scope is read as a route refusal's is, and so is the gap.** The
  row's `scope` is read from the address row named by the scope half of
  ADR-0005, section 4's composed key
  (`StatifierRouter.Addresses.by_execution/2`, read at `3dcd54f`), exactly
  as the sr-p6u Note reads it. A sender with no address row is told
  `delay` and nothing is recorded, because the ledger's `scope` is
  `NOT NULL`. Section 6's sentence that a refusal with no ledger row is
  `unaddressed_sender` and nothing else takes this one exception: the
  delay is refused whatever the address, so it is checked first, and a
  sender told `unaddressed_sender` would be sent to fix an address only
  to meet this refusal next.
- **What this Amendment does not decide.** Support is left to a later
  record: a timer-queue row that carries the reserved target and a fire
  path that delivers it through `StatifierRouter.Delivery.deliver_event/4`.
  It changes no immediate send, no other reason and no configuration-time
  refusal, and it leaves line 3 as it is. The code half is the first
  clause of `StatifierRouter.SendHandler`'s `enqueue/4`, in the same
  change as this Amendment.

## Note (2026-09-23, sr-n7c): the delay Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The `Status:` line of the `## Amendment (2026-09-23,
sr-73n)` moved from `proposed` to `accepted` on the operator's word of
2026-09-23, in session, after its code shipped in statifier_router
0.4.0 (tag `v0.4.0`, at `fdf4071`). The record's own status on line 3
was already `accepted` and was not touched, and the record's row in
`docs/adr/README.md` carries that status rather than the Amendment's,
so it does not move.

Every claim the Amendment makes was re-verified by anchor at `fdf4071`,
and each holds:

- `StatifierRouter.Config.new/1` refuses a route registered under the
  reserved name with `{:reserved_route, name}`, in its private
  `route_adapters/1`.
- The first clause of `StatifierRouter.SendHandler`'s `enqueue/4`
  matches a delayed send whose target is the reserved name on either
  shape, before the route registry is asked and without reaching the
  timer queue, and answers `{:error, {:send_refused, :delay}}`.
- Its ledger row is written by the handler's private refusal writer
  under the reason `delay`, with `key` and `execution_id` empty and
  `scope` read through `StatifierRouter.Addresses.by_execution/2` on
  the composed key's scope half; a sender with no address row gets no
  row.

## Amendment (2026-09-24, sr-a7e): a live session's sends resolve in the scope the host names in `:processor_scope`

Status: proposed

Section 1 holds that the scope is the sender's and never a param. At the
executor seam the scope a route override is read in is the delivery's:
`StatifierRouter.Delivery` names it for the length of its transaction
(`StatifierRouter.SendHandler.put_delivery_scope/1`, `@doc false`, read
at `8b6bb8b`). The send-processor shape is reached by no delivery, so a
live `Statifier.Session`'s send had no scope, and ADR-0005's Amendment of
2026-09-23 (sr-ha3) left it resolving to an overridden route's registered
configuration, saying a public way to name a scope on that shape was a
separate change. This Amendment is that change. Ruled by the operator,
2026-09-24; the code lands in the same change.

- **The host names the scope in the configuration.**
  `StatifierRouter.Config.new/1` takes one more option,
  `:processor_scope`: a non-empty string, or a zero-arity fun, and `nil`
  by default. Any other value is refused as
  `{:invalid_value, :processor_scope, value}` (the private
  `processor_scope/1` in `StatifierRouter.Config`).
- **A string is the scope of every send; a fun is asked per send.** On
  the send-processor shape `perform/2` resolves a send and a delayed send
  whose target names a registered route in that scope, so the scope's
  `:route_overrides` entry is merged over the registered configuration as
  `StatifierRouter.Config.route/3` merges it. A fun is called by
  `perform/2`, in the process that performs the send, once for each such
  send, and answers the scope or `nil`; it is never called for a target
  that names no registered route, which misses first as before (the
  processor arm of `StatifierRouter.SendHandler`'s private `resolve/3`).
- **A configuration that names no scope resolves as before.** With
  `:processor_scope` absent, or a fun that answers `nil`, the lookup is
  ADR-0005's Amendment of 2026-09-23 unchanged: an overridden route
  resolves to its registered configuration, with no override applied and
  no error (the handler's private `processor_scope/1`).
- **A fun that answers anything else is a miss.** `perform/2` answers
  `{:error, {:invalid_value, :processor_scope, value}}`, no route is
  called and nothing is queued. It is a miss the host reports, as every
  other `{:error, reason}` from `perform/2` is except `no_config`: the
  engine discards `perform/2`'s return (`Statifier.Session`'s
  `perform_instruction/3` clause for a handler instruction, at statifier
  2.7.0, the version `mix.lock` resolves).
- **The scope is still never a send param.** The host names it; a chart
  cannot. A `scope` param on a `<send>` is data like any other and names
  nothing. `put_delivery_scope/1` stays `@doc false`: it is the seam a
  delivery sets, not a door a host calls.
- **The executor seam does not read it.** `handle_effect/3` and the
  completion hook resolve in the delivery's scope, and with none in reach
  they refuse a route some scope overrides as
  `{:no_delivery_scope, name}`, as ADR-0005's Amendment of 2026-09-23
  decided; `:processor_scope` changes nothing there.
- **What this Amendment does not decide.** It changes neither half of the
  idempotency key (the scope half is still the session id on this shape,
  ADR-0005, section 4), nor the scope a refusal's ledger row is read in
  (the sender's address row, as the sr-p6u Note has it), nor the execution
  target on the send-processor shape, which is a later change. It grows
  the public configuration, so it ships in a minor.
