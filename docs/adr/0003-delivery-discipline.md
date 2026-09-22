# ADR-0003: Delivery discipline: one transaction per delivery over the host's repo, step/5 inside it, the address race settled by the unique index, the three create modes, step/5's lock as the per-key guarantee, and dedupe on (binding, message_id) with a row expiry

Status: proposed

## Context

ADR-0001 gives every binding a `create` mode, a `dedupe` horizon and an
`order`, and leaves what they do at delivery to this record. ADR-0002 gives
the address table, says the router mints the execution id, and leaves the
get-or-create transaction, its race and how the scope rides with an event
to this record. The outcome-vocabulary record names what a delivery can
end in and where each outcome is recorded. What is left is the delivery
itself: given a binding whose `match` held and whose `key` produced a
string, how does the event reach exactly one execution, once?

The four nouns are used each for itself. A **document** is the stable thing
an author edits and names. A **revision** is one saved state of a document.
A **chart** is what a revision compiles to. An **execution** is one
durable, stepped instance of one chart.

Facts outside this package that bound the answer, each read at
statifier_persistence a1a83a2 unless it says otherwise:

- **The input log has one writer.** `StatifierPersistence.Executions.step/5`
  appends the event it steps to the execution's input log inside its own
  serialized unit, and nothing else appends a delivered event
  (sp-ADR-0010, section 5, "Seven doors, one write site, and only inputs
  the interpreter saw"). A router that appended as well would log the
  event twice and replay it twice.
- **Both doors run inside a transaction the caller opened.** On the Ecto
  adapter, `Executions.create/4` and `Executions.step/5` called inside a
  transaction the caller opened on the same repo, from the same process,
  write through that transaction: a rollback leaves no execution row and
  no input row, and a commit keeps both. Effects fire before the commit and
  a rollback does not undo them. The per-execution lock is held until the
  caller commits, so another connection stepping the same execution waits
  for that commit. And an `{:error, :execution_exists}` refusal from
  `create/4` aborts the caller's whole transaction, after the refused
  create has already fired its initialize effects (statifier_persistence
  README, "Writing inside a caller's transaction", at statifier_persistence
  13fdb64).
- **step/5 already serializes one execution.** A second `step/5` for an
  execution waits while the first holds its lock, then steps from the
  position the first one wrote; a step the first one made terminal is
  discarded and not logged. Neither shipped adapter bounds the wait, and on
  the Ecto adapter a waiting call holds a pooled connection for the whole
  wait (statifier_persistence README, "Delivering while a step is in
  flight").
- **Effects are at least once, and their keys are the consumer's to
  dedupe on.** A step that is re-driven re-emits the same effects with
  identical deterministic keys, and the stepper never dedupes
  (sp-ADR-0004, decision 3).

## Decision

### 1. One transaction per delivery, over the host's repo

Each delivery is one transaction, opened by the router on the host's repo,
in the process that routes the event. The statifier_persistence store the
router is handed is built over that same repo, so `create/4` and `step/5`
join the transaction rather than opening their own. One delivery is one
binding's delivery of one event: an event that reaches two bindings is two
transactions, so a failure on one binding does not undo the other's, and
no transaction holds two executions' locks at once.

The transaction writes, in this order:

1. the dedupe row for `(binding_id, message_id)`, inserted if absent
   (section 6); when one is present and unexpired, the delivery is a
   duplicate, and the transaction writes the ledger row and nothing else;
2. the address insert-or-lookup of ADR-0002 (section 3 says how the
   insert settles a race, section 4 which of the two each `create` mode
   does), stamping `terminal_seen_at` when it finds the execution
   terminal and the stamp is still empty, so the horizon counts from the
   first sighting (ADR-0002, section 5);
3. when the binding's `create` mode calls for one (section 4),
   `create/4`, under an execution id the router mints for it (ADR-0002,
   section 3) and on the chart the host's resolver names (ADR-0002,
   section 4);
4. `step/5`, handed the event, unless the execution is terminal;
5. the ledger row the outcome-vocabulary record defines.

**The input log is written only by `step/5`, at statifier_persistence's
one write site (sp-ADR-0010, section 5); the router never appends to it.**
Nothing in this package calls `StatifierPersistence.Storage.append_input/4`
or any other writer of the input log.

An `{:error, reason}` from any of these steps, from the resolver, or from
the repo rolls the whole transaction back and is `route/3`'s `{:error,
reason}`: no dedupe row, no address row, no execution, no input and no
ledger row survive it.

A raise inside the delivery rolls it back the same way. The likeliest one
is a lock wait that the repo's query timeout, the server or a dropped
connection ends: statifier_persistence takes the execution's lock with a
query that raises on failure, and its Ecto adapter's `lock_execution/3`
lets a raise roll back and propagate (that function's documentation, read
at statifier_persistence a1a83a2), so the host's repo rolls back the whole
delivery transaction and re-raises. Nothing the transaction wrote
survives, and any effect already fired stays fired, as section 2 says.
`route/3` does not rescue it: the raise propagates to `route/3`'s caller.
The rollback has already happened by then, so nothing is left half
written, and rescuing would mean catching whatever the host's repo and
executor raise and turning a fault into an `{:error, reason}` nobody
can tell apart from an expected one; this package does not rescue to a
default. A front treats a raise as it treats `{:error, reason}`: it does
not acknowledge the message, and the source hands it over again.

### 2. step/5 runs inside the transaction, not after the commit

`step/5` runs inside the delivery's transaction, as step 4 above, and the
ledger row is the only write after it.

The reason is the gap the other choice opens. If `step/5` ran after the
commit, a committed dedupe row, address row, execution and ledger row
would stand for an event no execution has stepped yet, and a crash before
the step would leave it that way. The redelivery would then find the
dedupe row and record a duplicate, so the event would be lost unless
something went looking for committed, unstepped deliveries and stepped
them; that something is a process or a scheduled sweep with a pending
state of its own, and this package runs no process. Inside the
transaction, every committed delivery has its input in the execution's log,
and every rolled-back one left nothing behind in the router's tables or
statifier_persistence's to go looking for.

The failure window of this choice is the effects. `create/4` and `step/5`
hand their effects to the host's executor before the transaction commits,
and a rollback after them does not un-fire those effects: the host's side
effects happened, and the execution change that produced them did not.
Two things follow, and hosts must plan for both:

- A rollback after `step/5` on an existing execution rolls back the step;
  the redelivery steps the same event from the same position and re-emits
  the same effects with the same deterministic keys, which the effect
  consumer already has to dedupe on (sp-ADR-0004, decision 3).
- A rollback after `create/4` rolls back the execution. The redelivery
  creates again under a newly minted id, and ADR-0002 forbids deriving the
  id from anything stable, so the effects fired the first time carry the
  id of an execution that never committed. A consumer that dedupes on the
  execution id does not recognise the second firing as a repeat.

The window is kept short by the order in section 1: after `step/5` there
is one insert and the commit. Because the per-execution lock is held
until the commit, keeping that tail short also keeps any other delivery
to the same execution from waiting on more than the step itself.

### 3. The address race is settled by the unique index, and the loser never creates

Two first events for one key, routed at once, each find no address row.
The address write is therefore an **insert that, on a conflict with the
unique index, inserts no row and does not fail the transaction** (on
Postgres, `INSERT ... ON CONFLICT DO NOTHING`), and it runs **before**
`create/4`, carrying the id the router has just minted. The router knows
there was a conflict because the insert inserted no row; the insert does
not hand back the row it conflicted with, which that statement cannot
see. The unique index on `(scope, document, key)` settles the race: the
first insert wins, and the second waits for the first transaction to
end. If the first commits, the second inserts no row, and a following
statement in the same transaction reads the winner's row, whose
execution it steps: it is delivered, not created. If the first rolls
back, the second's insert proceeds and it creates.

The loser never calls `create/4`. That matters twice over: a `create/4`
it called would fire its chart's initialize effects, and if it named an
id that already existed, its `{:error, :execution_exists}` would abort the
whole transaction. `create/4` is only ever called with the id minted in
the same transaction and just written to the address row, so it names no
existing execution; an `{:error, :execution_exists}` from it is an error
under section 1, not a race to retry.

The lookup after a conflict relies on that following statement seeing
the winner's committed row, which holds at Postgres's default isolation, read
committed; a host that runs the delivery transaction at a stricter
isolation level is outside this record.

### 4. The three create modes

| `create` | The address has no row | The row's execution is active | The row's execution is terminal |
|---|---|---|---|
| `:if_absent` | insert the row, `create/4`, `step/5`: created_and_delivered | `step/5`: delivered | stamp `terminal_seen_at` if it is still empty, no step: dropped: finished |
| `:never` | no row is written, no create, no step: dropped: no_execution | `step/5`: delivered | stamp `terminal_seen_at` if it is still empty, no step: dropped: finished |
| `:always_new` | no row is read or written; `create/4`, `step/5`: created_and_delivered | (the address is not read) | (the address is not read) |

- **`:if_absent`** creates when the address has no row and delivers to the
  existing execution when it has one: Temporal's Signal-With-Start
  semantics (prior art below).
- **`:never`** delivers only to an existing execution. It reads the
  address and never inserts; a miss is the recorded drop.
- **`:always_new`** creates one execution per delivery, the per-event
  fan-out shape. It writes no address row, as ADR-0002, section 7 decides,
  so its executions are reached by their ids alone.

Under every mode, whether the execution is terminal is read from its
status (`StatifierPersistence.Storage.fetch_execution/2`) before `step/5`
is called, and an execution that `create/4` returns already terminal
(its chart finished while it was initialized) is not stepped either. A
`{:discarded, execution}` from `step/5` itself, for an execution that
became terminal after that read, is the same drop.

### 5. Per-key serialization is step/5's lock wait; a partitioner is an optimisation

The guarantee that two events for one execution are stepped one at a time
is `step/5`'s own lock: a second delivery to the same execution waits for
the first, and inside the delivery's transaction it waits until the
first's commit (statifier_persistence README, "Delivering while a step is
in flight", at statifier_persistence a1a83a2). Nothing in this package
adds a lock of its own, and nothing in it relies on where an event was
processed for correctness.

A front partitioner, Broadway's `partition_by` keyed on the binding's key,
is an **optimisation**: it keeps one key on one processor, so deliveries
for a key arrive one after another instead of queueing on the lock, each
holding a pooled connection while it waits. It is never the guarantee.
Deliveries that do not pass through the front, a host's webhook controller
among them, are serialized by the same lock.

### 6. Dedupe on (binding, message_id), with a row expiry

- **The key.** Dedupe is keyed on `(binding_id, message_id)`, one table,
  unique on the pair. Each row carries `expires_at`, the time it was
  written plus the binding's `dedupe` horizon, `horizon_ms` (ADR-0001,
  section 1; 72 hours by default).
- **The expiry is a row expiry.** A row whose `expires_at` has passed
  counts as absent, even before it is removed, and the next delivery of
  that pair replaces it. Nothing keeps an unbounded set of seen ids.
- **What writes a row.** Every delivery transaction that gets past the
  dedupe step writes the row, whatever its outcome (delivered,
  created_and_delivered or either drop), and the row commits or rolls back
  with that outcome. A rolled-back delivery leaves no row, so its
  redelivery is attempted again rather than taken for a duplicate.
- **A duplicate writes nothing else.** When the pair's row is present and
  unexpired, the outcome is duplicate, and the transaction writes its
  ledger row and nothing else: no address row, no execution, no step. Two
  concurrent deliveries of one pair are settled as in section 3: the
  second insert waits for the first transaction, then inserts no row
  (a duplicate) or proceeds.
- **A queue source's message id is structural.** For a queue source, the
  source adapter derives the message id from the message's own position in
  the source (for a partitioned log, its topic, partition and offset),
  which is unique by construction and the same on every redelivery. The
  code that hands the event to the router never chooses one.
- **A webhook's message id is the provider's.** For a webhook, the message
  id is the provider's event id when the provider sends one, and otherwise
  a hash of the request body after its signature has been verified, so a
  provider's retry of the same body is the same message.
- **The adapters are the host's.** This package ships no source adapter
  and no webhook helper; the two rules above bind whoever builds the
  message id, and the router takes the id it is handed.

### 7. The router's dedupe and the engine's never merge

The router's dedupe protects the **edge**: the same message handed to the
router twice, by a queue that redelivers or a provider that retries. The
engine's protection is for the **retry** of a step: a re-driven step
re-emits its effects with identical deterministic keys, and their
consumer dedupes on those (sp-ADR-0004, decision 3). They answer different
questions about different things, and neither stands in for the other: a
dedupe row never suppresses a re-driven step's effects, and an effect key
never decides whether a message is a duplicate. Neither is extended to
cover the other.

### 8. How the scope rides with an event

The host hands the scope with each event, as a field of the event it
passes to `route/3`, beside the message id and the normalized event. A
binding carries no scope, and nothing in the router derives one.

### 9. No process

Expired dedupe rows are removed by a plain function the host schedules,
beside ADR-0002's `reap/2`; it deletes rows whose `expires_at` has passed,
and nothing else. This package starts no process to call it, and runs no
process, supervisor or scheduler of any kind.

### 10. order: :none is no partition, nothing more

A binding whose `order` is `:none` declares that its chart is commutative
over the event, so a front need not keep its events in order per key. In
this release that means exactly one thing: the front does not partition
that binding's events by key. It does not batch them, reorder them, or
skip the lock; two deliveries to one execution are still stepped one at a
time (section 5), in whatever order they reach the lock. `:by_key`, the
default, partitions by the binding's key.

### Prior art

- Temporal's Signal-With-Start, the `:if_absent` semantics: signal the
  running workflow execution with the given id, or start one and signal
  it. <https://docs.temporal.io/sending-messages>
- Restate's virtual objects, per-key serialization held by the runtime,
  not by the caller: at most one handler with write access runs at a time
  per object key. <https://docs.restate.dev/concepts/services>
- DBOS's Kafka integration, the structural message id: an idempotency key
  built from the message's topic, partition and offset.
  <https://www.dbos.dev/blog/exactly-once-apache-kafka-processing>
- Broadway's partitioning, the front optimisation: messages in one
  partition are processed in order.
  <https://broadway.hexdocs.pm/Broadway.html#module-ordering-and-partitioning>
- PostgreSQL's `INSERT ... ON CONFLICT DO NOTHING`, the insert that
  inserts no row on a conflict and does not fail the transaction.
  <https://www.postgresql.org/docs/current/sql-insert.html>

### The example: an impression and its click

The two bindings of ADR-0001's example, `impressions_to_join` and
`clicks_to_join`, take the defaults: `create: :if_absent`, a 72-hour
horizon and `order: :by_key`. Under the scope `"7c1e"`:

- The impression `ad_events/3/1042` for `imp_7f3a` reaches
  `impressions_to_join`. One transaction inserts the dedupe row
  `("impressions_to_join", "ad_events/3/1042")`, finds no address row for
  `("7c1e", "impression_click_join", "imp_7f3a")`, mints `ex_9k2q` and
  inserts the row, calls `create/4` under `ex_9k2q` on the chart the
  resolver names, calls `step/5` with the `impression` event, and writes
  the ledger row. It commits: created_and_delivered.
- Suppose the click `ad_events/3/1107` for the same impression is routed
  by a second consumer of the source while that transaction is still
  open. Its transaction inserts
  its own dedupe row, and its address insert waits on the unique index.
  When the first commits, the insert inserts no row; a following
  statement reads the row, finds `ex_9k2q` active and calls `step/5`, which steps the `click`
  after the `impression`. It commits: delivered. `ex_9k2q`'s input log
  holds the impression, then the click.
- The source redelivers `ad_events/3/1107`. Its dedupe row is present and
  unexpired: the transaction writes the ledger row and nothing else.
  duplicate.
- Had the connection failed between the click's `step/5` and its commit,
  the transaction would have rolled back: no dedupe row, no ledger row, no
  input. The click's effects would already have fired; the redelivery
  steps it again from the same position and re-emits them with the same
  keys.

## Consequences

- A committed delivery is complete: its dedupe row, its address row, its
  execution, its input and its ledger row commit together, and a
  rolled-back one leaves none of them. No sweep is needed to finish a
  delivery, and none exists.
- Effects fired inside a delivery that rolls back have happened anyway.
  Hosts' executors already have to be idempotent on effect keys; a
  rollback after a create adds a case the effect key alone does not
  catch, because the redelivery creates under a new execution id.
- A delivery holds the execution's lock until it commits. A slow
  transaction delays every other delivery to that execution, and each
  waiting delivery holds a pooled connection; the partitioner keeps that
  queue off the pool for events that come through the front.
- The race between two first events costs the loser a wait and a lookup,
  never a second execution and never an aborted transaction.
- The input log stays the engine's alone, so a replay sees exactly the
  inputs the interpreter saw, once each.
- A message is handled at most once per binding per horizon; after the
  horizon, a redelivery of the same message is handled again. A host that
  needs a longer memory lengthens the horizon.
- Retention needs a host that calls the dedupe reaper. A host that never
  schedules it keeps every row, which is correct and only costs space,
  since an expired row already counts as absent.
- This record leaves to the code half: the dedupe table's migration and
  name, the reaper's name, the id format, and the exact field that carries
  the scope in `route/3`'s argument.

## Note (2026-09-20, sr-5pi): the snapshot options a delivery carries, the store's repo, and what section 1's resolver error is actually called

A Note, not an amendment: it decides nothing above, and section 1
stands as written. It records one new option and corrects one sentence.

- **The delivery carries the host's per-call snapshot options.** Until
  now `:executor` was the only option this package passed to
  `StatifierPersistence.Executions.create/4` and
  `StatifierPersistence.Executions.step/5`, so a chart needing a custom
  invoke type, a send route or a registered send type could not be
  delivered at all: statifier_persistence defaults each snapshot to
  `nil`, and, from its 0.13.0 release on, a `<send>` whose type the
  execution was not given classifies as unsupported (its `create/4` and
  `step/5` option docs, at statifier_persistence 9cd192b). `StatifierRouter.Config` gains
  `:persistence_options`, a keyword list over `:routes`,
  `:invoke_types` and `:send_types`, empty by default, carried onto
  every create and every step of every delivery. It is a standing
  snapshot, one per configuration, so it takes none of the per-execution
  options (`:initialize`, `:metadata`) and none of the configuration's
  own.
- **A create takes the snapshot inside `initialize:`; a step takes it
  beside the event.** `Statifier.MachineState.new/2` is the one writer
  of the fields the snapshot sets, and a create has no stored position
  to stamp, so an option passed top-level to `create/4` type-checks and
  is ignored for the execution's whole life. statifier_persistence says
  so in its `create/4` option docs and places `invoke_types:` that way
  in its own driver. The two doors are not symmetric, and
  `StatifierRouter.Delivery` builds their option lists separately.
- **The store must be built over the configuration's repo, and `new/1`
  now says so where it can see it.** Section 1 requires one transaction
  per delivery over the host's repo, with both doors writing through
  it; a store over another repo writes outside it, and a rollback then
  leaves the execution behind. `StatifierRouter.Config.new/1` refuses a
  store whose resolved adapter options name a different repo. Only
  statifier_persistence's Ecto storage resolves a `:repo` into those
  options, so on any other adapter the rule is stated and not checked.
- **A resolver error is `{:error, {:unresolved_document, document,
  reason}}`.** Section 1's own prose calls it `route/3`'s
  `{:error, reason}`. The code wraps it - `StatifierRouter.Delivery`'s
  `resolve/3` - beside `{:error, {:chart_not_resolved, content_hash}}`
  for a chart resolver that answers `:error`, which is the shape
  ADR-0004, section 7 asks for. Read section 1's sentence as naming the
  wrapped term.
- **`:resolver` and `:executor` are checked to different depths on
  purpose.** `StatifierRouter.Resolver` is this package's behaviour, so
  a resolver module is required to be loadable and to export
  `resolve/2`. `StatifierPersistence.Executor` is the dependency's, and
  it normalizes a module or an arity-2 fun itself, so this package
  checks the option's shape and leaves the dispatch rule to its owner.
  `StatifierRouter.Config`'s documentation carries the same paragraph.

## Note (2026-09-21, sr-bv1): redelivery is the producer's contract, and this package now ships a webhook helper

A Note, not an amendment: it decides nothing above. It corrects one
sentence that assumes a producer, and one half of one bullet that a later
release overtook.

- **A front that does not acknowledge a message does not thereby get it
  back.** Section 1's closing sentence says a front "does not acknowledge
  the message, and the source hands it over again", and the consequence
  list's "a redelivery of the same message" reads the same way. That holds
  only for a source that redelivers what it was not acknowledged for.
  Broadway, the front this package ships, provides no retries of its own
  and acknowledges a failed message as failed immediately (Broadway's own
  documentation, "Acknowledgements and failures"), so redelivery is the
  **producer's** contract: a queue-style producer that leaves an
  unacknowledged message invisible for a timeout hands it over again, and
  `BroadwayKafka.Producer` always acknowledges a message even when it
  fails and advances the group's offset past it, leaving reprocessing to
  the host (BroadwayKafka's own documentation, "Handling failed
  messages"). Read section 1's sentence, and every "the redelivery"
  elsewhere in this record, as conditional on a source that redelivers.
  Nothing else in the record changes: the dedupe horizon of section 6 and
  the rollback behaviour of section 2 are the same whether or not a
  message comes back, and a message that never comes back is one delivery
  that did not happen, which this record already treats as a rolled-back
  delivery that left nothing behind. `StatifierRouter.Broadway`'s module
  documentation says the same, and neither this package nor its front
  holds or retries a failed message.
- **Section 6's last bullet is half stale: the webhook helper now ships.**
  That bullet says "This package ships no source adapter and no webhook
  helper". The webhook half stopped being true when
  `StatifierRouter.Webhook.handle/3` landed: it takes a request the host
  has already verified, chooses the message id by the rule the two bullets
  above it state, and hands the event to `StatifierRouter.route/3`
  (`lib/statifier_router/webhook.ex`, read at 4fb206b). **The
  source-adapter half still stands**: this package ships no source
  adapter, and the structural message id of a queue source is still
  derived by whoever builds it. The two message-id rules themselves are
  unchanged by the helper - it implements the webhook one rather than
  replacing it - and a host's own webhook controller, which section 5 and
  the outcome-vocabulary record both mention, stays the host's: the helper
  is a Plug-shaped function a controller calls, not a controller.
