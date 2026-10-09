# ADR-0003: Delivery discipline: one transaction per delivery over the host's repo, step/5 inside it, the address race settled by the unique index, the three create modes, step/5's lock as the per-key guarantee, and dedupe on (binding, message_id) with a row expiry

Status: accepted

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
  the message, and the source hands it over again", and four later
  passages assume that handover rather than supposing it: section 2's
  "The redelivery would then find the dedupe row"; its rollback
  consequence, where "the redelivery steps the same event from the same
  position"; the bullet after it, "A rollback after `create/4` rolls back
  the execution. The redelivery creates again under a newly minted id";
  and section 6's "its redelivery is attempted again rather than taken
  for a duplicate". That holds only for a source that redelivers what it
  was not acknowledged for.
  Broadway, the front this package ships, provides no retries of its own
  and acknowledges a failed message as failed immediately (Broadway's own
  documentation, "Acknowledgements and failures"), so redelivery is the
  **producer's** contract: a queue-style producer that leaves an
  unacknowledged message invisible for a timeout hands it over again, and
  `BroadwayKafka.Producer` always acknowledges a message even when it
  fails and advances the group's offset past it, leaving reprocessing to
  the host (BroadwayKafka's own documentation, "Handling failed
  messages"). Read section 1's sentence, and every later passage that
  speaks of "the redelivery" or "its redelivery", as conditional on a
  source that redelivers. The Consequences list's "after the horizon, a
  redelivery of the same message is handled again" needs no such reading:
  it is already conditional, saying what happens if a redelivery arrives
  rather than that one does. Nothing else in the record changes: the
  dedupe horizon of section 6 and the rollback behaviour of section 2 are
  the same whether or not a message comes back, and a message that never
  comes back is one delivery that did not happen, which this record
  already treats as a rolled-back delivery that left nothing behind.
  `StatifierRouter.Broadway`'s module documentation says the same, and
  neither this package nor its front holds or retries a failed message.
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

## Note (2026-09-22, sr-a69): accepted

A Note, not an amendment: it decides nothing above, and every section
stands as written. It records the status flip and what was re-read to
license it.

- **The flip.** `Status:` reads `accepted` as of this Note, on the
  operator's word given after statifier_router 0.2.0 was published. The
  status word is the only line above this Note that changed.
- **Every claim was re-verified at `0cea19c`.** Each sentence this record
  makes about this package's code was re-read by anchor at that commit
  before the flip, and each held. The verdicts, one per claim, are
  enumerated in the pull request that carried this Note.
- **No body sentence speaks of this record's own status.** The body was
  searched for one; the only other occurrence of the word is section 4's
  reading of an *execution's* status through
  `StatifierPersistence.Storage.fetch_execution/2`, which is a different
  thing. So nothing above is left saying something the flip contradicts,
  and nothing above needed rewording.
- **Section 9's "runs no process" was read against the front this package
  now ships.** `StatifierRouter.Broadway` is a `Broadway` pipeline module,
  and section 9 still holds as written: the host starts that pipeline in
  the host's own supervision tree, and the package starts nothing. The
  module's own documentation says so, `mix.exs` gives the application no
  `mod:` entry, so this package's own OTP application starts nothing, and
  ADR-0005 and ADR-0006 both describe this package as driven process-less.
- **The Context's four claims about statifier_persistence were not
  re-audited, and are anchored where the record anchors them.** The
  single-writer input log, both doors writing through a caller's
  transaction, `step/5`'s own serialization and effects being at least
  once are claims about the dependency's behaviour, each read at the
  statifier_persistence commit the Context names; this flip moves no pin,
  leaving `mix.lock` unchanged, so it re-verified this package's own
  sentences and left those four standing on their cited anchors. A later
  flip or amendment that also moves that pin re-audits them.
- **The two earlier Notes stand unchanged.** The sr-5pi Note
  (2026-09-20) and the sr-bv1 Note (2026-09-21) are part of what is
  accepted here; the sentences they qualify are read as they qualify them.
- **Two open questions sit against this record, and the flip decides
  neither.** `sr-7v9` asks whether `StatifierRouter.Broadway`'s partitioner
  should rescue a host `:normalize` that raises, or whether taking the
  producer stage down is the intended contract. Nothing is acknowledged
  when it happens, so section 1's rollback guarantee is unaffected either
  way; the answer is an amendment or a new record, not a reading of this
  one. `sr-37a` sits beside it: section 1 says a raise inside the delivery
  "rolls it back the same way" and that "nothing is left half written",
  and what was measured is that such a raise also destroys the **enclosing**
  transaction, a rescue inside it not being enough, because the next
  statement raises `DBConnection.ConnectionError` with "transaction rolling
  back" and the connection disconnects. Section 1's sentence does not
  caveat that, and this flip does not clear the tension; it is named here
  so the next reader meets it, and deciding it is a record's call.
- **The index lags by design.** The status cell for this record in
  `docs/adr/README.md` is flipped by a separate bead after all seven
  records have flipped.

## Amendment (2026-09-23, sr-d2u): a delivery settles its error at a savepoint of its own, so it may run inside a caller's transaction

Status: accepted

Section 1 says that an `{:error, reason}` from any step of a delivery
"rolls the whole transaction back and is `route/3`'s `{:error, reason}`".
It was written for `route/3` as the outermost transaction on its path,
which is how this package's own fronts call it. Nothing stops a host from
calling `route/3` inside a transaction of its own, and there a rollback
does not do what section 1 says.

- **The cause.** The delivery's transaction nests inside the caller's,
  and db_connection answers a nested transaction with a clause that drops
  its options: `def transaction(%DBConnection{conn_mode: :transaction} =
  conn, fun, _opts)` in `DBConnection`, at db_connection 2.10.2, the
  version this package's `mix.lock` resolves. So `mode: :savepoint`
  creates no savepoint there, and a `c:Ecto.Repo.rollback/1` inside marks
  the connection failed. The caller is answered `{:error, reason}` while
  its own transaction is already lost: its next statement raises
  `DBConnection.ConnectionError` with "transaction rolling back".
- **The decision.** A delivery settles an `{:error, reason}` the way
  `StatifierRouter.Delivery.deliver_event/4` already settles one
  (ADR-0006, section 2): it runs inside an explicit SQL savepoint of its
  own, rolls back to that savepoint on an error, and answers the reason as
  an ordinary return. Neither door calls `c:Ecto.Repo.rollback/1`.
- **Section 1's guarantee holds where it was written.** When `route/3` is
  the outermost transaction, the rollback to the savepoint leaves the
  transaction holding nothing of the delivery's and it commits empty: no
  dedupe row, no address row, no execution, no input and no ledger row
  survive, as section 1 lists. When a host calls `route/3` inside its own
  transaction, the error undoes the delivery's writes and nothing of the
  host's, and the host's transaction stays usable.
- **A raise is unchanged.** Section 1's paragraph on a raise still holds:
  nothing rescues it, it propagates, and it takes any enclosing
  transaction with it. A savepoint does not keep a transaction open
  against a raise; the sr-a69 Note above names that tension, and this
  Amendment does not decide it.
- **The savepoint statements are statements.** On a connection that has
  gone away, the rollback to the savepoint raises instead of the delivery
  answering `{:error, reason}`. That raise is section 1's raise case.
- **The host's repo answers `query!/1`.** `deliver_event/4` already needed
  it for the same bracket, and every `Ecto.Adapters.SQL` repo does.

**Where the code is.** `StatifierRouter.Delivery`, whose module
documentation says the same where an implementer will read it, in the
pull request that carries this Amendment. The delivery tests pin it with a
host transaction that calls `route/3`, meets an unresolved document, and
still commits the row it wrote before the call.

## Note (2026-09-23, sr-n7c): the savepoint Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The `Status:` line of the `## Amendment (2026-09-23,
sr-d2u)` moved from `proposed` to `accepted` on the operator's word of
2026-09-23, in session, after its code shipped in statifier_router
0.4.0 (tag `v0.4.0`, at `fdf4071`). The record's own status on line 3
was already `accepted` and was not touched, and the record's row in
`docs/adr/README.md` carries that status rather than the Amendment's,
so it does not move.

Every claim the Amendment makes was re-verified by anchor at `fdf4071`,
and each holds. `lib/statifier_router/delivery.ex` has no commit since
the one that carried the Amendment.

- db_connection 2.10.2 is the version `mix.lock` resolves, and its
  `DBConnection.transaction/3` carries the quoted clause for a
  connection already in a transaction, which ignores its options.
- `StatifierRouter.Delivery`'s `deliver/4` and `deliver_event/4` both
  settle through one private function that opens an explicit
  `SAVEPOINT`, releases it on an outcome and rolls back to it on an
  `{:error, reason}`, answering the reason as an ordinary return
  through `query!/1`; no `c:Ecto.Repo.rollback/1` is called anywhere in
  `lib/`.
- Nothing in the delivery rescues a raise, and `StatifierRouter.route/3`'s
  documentation says a raise propagates.
- The module documentation says the same as the Amendment, and the
  delivery tests' "an error inside a host's own transaction undoes the
  delivery and nothing of the host's" is the pin the Amendment names:
  a host transaction that calls `route/3`, meets an unresolved
  document and still commits the row it wrote first.

## Amendment (2026-09-25, sr-vp1): a host may stand in for create/4 and step/5, and the transaction stays the delivery's

Status: accepted

Section 1 has the delivery call statifier_persistence's
`Executions.create/4` and `Executions.step/5` itself, inside its
transaction. A host whose own engine wraps those two calls - its own
context around them, its own rows beside them, its own redrive - has had
to choose between that wrapping and this package's transaction, savepoint,
dedupe and ledger. This Amendment lets it keep both.

- **The two keys.** `StatifierRouter.Config` takes two optional keys,
  `:on_create` and `:on_step`. Each is a module exporting the function it
  stands in for (`create/4`, `step/5`), called as `module.create/4` or
  `module.step/5`, or a fun of that function's arity. `Config.new/1`
  checks that shape and nothing more, and refuses any other value with
  `{:error, {:invalid_value, name, value}}`.
- **Their contracts are persistence's.** `:on_create` is handed
  `(store, execution_id, machine, opts)` and answers
  `{:ok, execution, state}` or `{:error, reason}`, the contract of
  `StatifierPersistence.Executions.create/4` at statifier_persistence
  0.18.0. `:on_step` is handed `(store, execution_id, machine, event,
  opts)` and answers `{:ok, execution, state}`, `{:discarded, execution}`
  or `{:error, reason}`, the contract of `step/5` at the same version.
  The arguments are exactly those the direct call would have been handed:
  the configuration's `:store`, the execution id the delivery minted or
  read, the chart the resolver or the chart resolver answered, the event
  the delivery built, and the snapshot options placed as the sr-5pi Note
  above places them.
- **The answer is read as persistence's would be.** The execution's
  status decides a finish (section 4 and ADR-0004, section 3), the
  state's `last_selection` decides an unmatched event (ADR-0004, the Note
  of 2026-09-25), a `{:discarded, execution}` from `:on_step` is a
  finish, the answered execution's donedata is what `:on_complete` hands
  on, and an `{:error, reason}` from either is the delivery's error. An
  answer outside the contract raises `ArgumentError`, as a malformed
  resolver answer does.
- **The transaction rule.** A hook is called where the direct call was,
  inside the delivery's transaction and inside its savepoint (the
  Amendment of 2026-09-23), after the dedupe claim and any address row
  and before the ledger row. What it writes through the configuration's
  repo joins that transaction: an `{:error, reason}` from the hook, or
  from anything after it, rolls back to the savepoint and takes the
  hook's own writes with the delivery's. A hook answers an error as a
  value and never calls `c:Ecto.Repo.rollback/1`, for the reason the
  Amendment of 2026-09-23 gives. A hook that writes through another repo
  or another connection writes outside the delivery and survives its
  rollback; that is the host's to keep, as the `:store` rule of section
  1 is. A raise from a hook is section 1's raise.
- **Both doors.** `deliver/4` and `deliver_event/4` reach the two calls
  through the same functions, so an execution-to-execution send is
  created and stepped through the hooks as a binding's delivery is.
- **Absent is today.** With neither key set, the delivery calls
  `create/4` and `step/5` itself, exactly as before this Amendment. The
  router still writes no input of its own: section 1's sentence on the
  input log binds this package, and a hook is expected to reach
  `step/5` itself inside its own wrapping.

**Where the code is.** `StatifierRouter.Config`, whose `hooks/1` checks
the two keys, and `StatifierRouter.Delivery`, whose
`persistence_create/4` and `persistence_step/5` make the call through the
hook or directly, in the pull request that carries this Amendment. The
persistence hooks tests pin the arguments against the direct call's, and
each arm of each contract.

## Note (2026-09-25): the sr-vp1 Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The operator accepted the `## Amendment (2026-09-25,
sr-vp1)` on 2026-09-25, and its `Status:` line moved from `proposed` to
`accepted`. Its code landed in PR 88 (`53d8118`) and shipped in
statifier_router 0.6.0 (tag `v0.6.0`, at `0854a99`). The record's own
status on line 3 was already `accepted` and was not touched.

Every claim was re-verified by anchor at `0854a99`, which is both the
tag and `main` at the time of the flip:

- `StatifierRouter.Delivery`'s private `persistence_create/4` and
  `persistence_step/5` call statifier_persistence directly when the key
  is `nil` and the host's hook otherwise.
- The tests are in `test/statifier_router/persistence_hooks_test.exs`.

**One anchor that is inexact.** The Amendment names the check as
`StatifierRouter.Config`'s `hooks/1`. It was `hooks/1` when the
Amendment landed (`53d8118`); the sr-1b2 Amendment on ADR-0002 widened
it to `hooks/2`, which checks the two keys and `:execution_id` with one
function. What it checks for `:on_create` and `:on_step` is as the
Amendment says.

## Note (2026-09-26, sr-zsa9): the unmatched-event drop the hooks Amendment names is the binding door's

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. It says which door one clause of the
Amendment of 2026-09-25 above, the create and step hooks, applies to,
because two of that Amendment's bullets read together suggest both.

Its bullet "The answer is read as persistence's would be" lists, among
the readings of a hook's answer, that "the state's `last_selection`
decides an unmatched event (ADR-0004, the Note of 2026-09-25)". Its
bullet "Both doors" says that `deliver/4` and `deliver_event/4` "reach
the two calls through the same functions". The second is true of the
calls: both doors reach `:on_create` and `:on_step` through the same
private functions. It is not true of what an answer whose state carries
`last_selection: :none` becomes.

- **A binding's delivery drops.** On `deliver/4`, the door a binding's
  delivery takes from `route/3` when `:delivery` is left at its default,
  a step whose answered state carries `last_selection: :none` is
  `{:dropped, binding_id, :unmatched_event}` and is recorded as
  `dropped: unmatched_event`, whether `step/5` or an `:on_step` hook
  answered it. `StatifierRouter.Delivery`'s private
  `taken/7` makes that outcome only for a `%StatifierRouter.Binding{}`
  plan.
- **An execution-to-execution send does not.** On `deliver_event/4`,
  the same answer keeps the delivered or created_and_delivered outcome
  ADR-0006 gives a send, as ADR-0004's Note of 2026-09-25 says under
  "Where it does not reach". The plan this door is handed is
  `StatifierRouter.SendHandler`'s own map, built in its private
  `deliver_to/5`, not a binding, so `taken/7`'s other clause records
  it. The execution target tests' "a send the receiving execution does
  not take" pins it.

The rest of that bullet - the execution's status deciding a finish, a
`{:discarded, execution}` from `:on_step` being a finish, the donedata
`:on_complete` hands on, and an `{:error, reason}` from either hook
being the delivery's error - is read the same way on both doors, in the
private `create/6` and `step/7` both doors share.

Every anchor above was read at `0bb620e`, `main` when this Note was
written: `lib/statifier_router/delivery.ex` for `taken/7`, `create/6`
and `step/7`, `lib/statifier_router/send_handler.ex` for
`deliver_to/5`, and `test/statifier_router/execution_target_test.exs`
for the test.

## Amendment (2026-10-02, sr-t36w): one optional wrapper runs a whole delivery inside a host's context, on the doors the router drives

Status: accepted

The create and step hooks of the Amendment of 2026-09-25 reach the create
and the step and nothing else a delivery does. A host whose repo and rows
read a tenancy context of its own - one held in the process, or a
transaction-local database setting - has had no seam that covers the
dedupe claim, the address row, the status read, the ledger row, the
bindings read or a `key_refused` row. This Amendment adds one. Its shape
was ruled by the operator, 2026-10-01: the wrapper is handed the scope,
the BasicHTTP front resolves its token outside it, and the execution-target
door is not wrapped.

- **The option.** `StatifierRouter.Config` takes one optional key,
  `:around_delivery`, defaulting to `nil`: a module exporting
  `around_delivery/3`, or a fun of arity 3. `Config.new/1` checks that
  shape and nothing more, as it checks the hooks, and refuses any other
  value with `{:error, {:invalid_value, :around_delivery, value}}`.
- **Its contract.** It is handed `(scope, door, work)`: the scope the
  delivery runs under, the door it came through, and a fun of arity 0
  that does the door's work. It calls `work` exactly once and answers
  what `work` answered. A wrapper that answers anything else, never calls
  `work`, or calls it twice raises `ArgumentError` once it returns, so a
  wrapper that hands back a `c:Ecto.Repo.transaction/2` answer, which
  wraps the work's answer in `{:ok, _}`, is refused rather than mistaken
  for a routing answer.
- **Absent is today.** With the key left out, no wrapper is called and
  every door runs its work directly: the router issues the same
  statements, in the same order, and answers the same as before the key
  existed.
- **The names.** `:around_delivery` says what the option does: it runs
  around a whole delivery, where `:on_create` and `:on_step` run in place
  of one call inside it. The doors are named for the entry point that
  calls the wrapper: `:route` for `route/3`, `:partition` for the
  partitioner, `:basichttp` for the front, whose plan name is the same
  word.

**Where the wrapper lives.** Not in the `:delivery` option. The BasicHTTP
front and `StatifierRouter.SendHandler` call
`StatifierRouter.Delivery.deliver_event/4` directly and never reach the
configuration's `:delivery` module, and `route/3` writes its `key_refused`
row and reads its bindings outside that module too. So the wrapper is
called by the entry points, around their call into `StatifierRouter.Delivery`,
and `StatifierRouter.Delivery` itself never calls it.

**The doors.** Every door that reads or writes for a delivery, and
whether the wrapper encloses it:

| Door | Wrapped | Door atom | What runs inside, or why not |
|---|---|---|---|
| `StatifierRouter.route/3` | yes | `:route` | the bindings read, every `key_refused` row and every binding's delivery, after the event and the options are checked; one call per `route/3` call, handed the event's scope |
| `StatifierRouter.Webhook.handle/3` | yes, through `route/3` | `:route` | as `route/3`; the webhook front reads and writes nothing of its own |
| `StatifierRouter.Broadway`'s `handle_message/3` | yes, through `route/3` | `:route` | as `route/3`, in the processor |
| `StatifierRouter.Broadway.partition/3` | yes | `:partition` | the bindings read for one message, in the producer's dispatcher, with no transaction open |
| `StatifierRouter.BasicHTTP.Front.handle/3` | the delivery only | `:basichttp` | the delivery, handed the address row's scope; the token's lookup runs before the call and outside it, because the scope is not known until the token resolves |
| the execution target, at the executor seam | no door of its own | none | it runs inside the sending execution's step; see the table below |
| the execution target, on the send-processor shape | no | none | no delivery of the router's is running; see the table below |
| `StatifierRouter.Delivery.deliver/4` and `deliver_event/4`, called by a host itself | no | none | the host's own call, which it wraps at the call |
| `subscribe/3`, `cancel/2`, `StatifierRouter.BasicHTTP.rotate_location/2` and the two reapers | no | none | host-called writes outside any delivery, which the host wraps at the call |

**The execution target, per shape.** The door is not wrapped. Whether a
wrapper encloses it depends on who drove the sending step:

| The sending step was driven by | Does a wrapper enclose the target's delivery |
|---|---|
| a wrapped door: a binding's delivery through `route/3`, or the BasicHTTP front | yes: the target's delivery runs inside the sender's step, in the same process and the same transaction, so the `:route` or `:basichttp` call around the sender's delivery encloses it and its context is the sender's |
| a step the router did not drive: a delayed event a timer job steps in, or a step the host makes itself | no: no door of the router's was called, and the host wraps the call that steps the execution |
| a live session on the send-processor shape (`SendHandler.perform/2`) | no: `deliver_event/4` opens the transaction itself and nothing of the router's encloses it; the host wraps its own call that performs the send |

So the target door is not always inside a wrapped step, and this Amendment
does not claim it is. Wrapping it on the shapes where no wrapper reaches
is not decided here.

**What a context reaches.** A context the wrapper holds in the process is
visible to every statement `work` runs, in the process that called the
wrapper; for the partitioner that is the producer's dispatcher. A
transaction-local setting is visible only inside a transaction: each
delivery opens its own, so a setting made before `work` reaches the
deliveries only when the wrapper opened a transaction on the
configuration's repo first, and the partitioner's read and a `key_refused`
row run in no transaction of the router's.

**A wrapper that opens a transaction.** A wrapper that runs `work` inside
a transaction of its own on the configuration's repo makes every delivery
of one `route/3` call commit together, or roll back together: each
delivery nests into it and settles its own error at its savepoint, which
the Amendment of 2026-09-23 allows. A host that wraps this way is told so
in `StatifierRouter.Config`'s documentation and in the README.

**Where the code is.** In the pull request that carries this Amendment:
`StatifierRouter.Config`'s `new/1` checks the key and its package-internal
`around_delivery/4` calls the wrapper or runs the work;
`StatifierRouter.route/3`, the private `bindings_for/2` of
`StatifierRouter.Broadway` and the private `deliver/5` of
`StatifierRouter.BasicHTTP.Front` call it. The anchors that predate this
Amendment were read at `bbe6c16`: `StatifierRouter.SendHandler`'s private
`deliver_to/5` and its `perform/2`, and `StatifierRouter.Delivery`'s
`deliver/4` and `deliver_event/4`. The tests are in
`test/statifier_router/around_delivery_test.exs`: one per wrapped door,
one for the execution target at the executor seam under a wrapped
`route/3` and one on the send-processor shape, one for a wrapper that
opens a transaction, one for the wrapper's contract, and one that
compares a configuration without the key against the statements captured
before the key existed.

## Note (2026-10-02, sr-4llw): the whole-delivery wrapper Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Records merge at proposed and are accepted
once their code has shipped in a published version and every claim they
make verifies against `main`, under the standing grant of the operator's
campaign consent of 2026-10-01. The `## Amendment (2026-10-02, sr-t36w)`
on the whole-delivery wrapper is such a record: its `Status:` line moved
from `proposed` to `accepted`. Its code landed in PR 152 (`b79fae8`, and
`be77380`, which drains the wrapper's reports on every way out of it)
and shipped in statifier_router 0.10.0 (tag `v0.10.0`, at `f823adb`,
published on Hex 2026-10-02T11:42:49Z). The record's own status on line
3 was already `accepted` and was not touched.

Every claim was re-verified by anchor at `f823adb`, which is both the
tag and `main` at the time of the flip:

- The option: `StatifierRouter.Config`'s `new/1` checks
  `:around_delivery` with its private `hooks/2`, the function that checks
  `:on_create`, `:on_step` and `:execution_id`: `nil`, a fun of arity 3,
  or a loaded module exporting `around_delivery/3` is taken, and any
  other value is `{:error, {:invalid_value, :around_delivery, value}}`.
- The contract and the absent key: the package-internal
  `StatifierRouter.Config.around_delivery/4` runs the work directly when
  the key is `nil`; otherwise it hands the wrapper `(scope, door, work)`,
  reads the work's reports once the wrapper returns, answers the work's
  answer when the work ran once and the wrapper answered it, and raises
  `ArgumentError` for any other answer or count. A wrapper that raises,
  exits or throws is re-raised with its own kind, reason and stacktrace.
- The wrapped doors: `StatifierRouter.route/3` calls it with `:route`
  and the event's scope around its private `route_event/3` (the bindings
  read, the private `key_refused/5` row and each binding's delivery),
  after `validate_event/1` and `fetch_now/1`;
  `StatifierRouter.Webhook.handle/3` and `StatifierRouter.Broadway`'s
  `handle_message/3` call `route/3`; `StatifierRouter.Broadway`'s private
  `bindings_for/2` calls it with `:partition` around
  `StatifierRouter.Config.bindings_for/2`; `StatifierRouter.BasicHTTP.Front`'s
  private `deliver/5` calls it with `:basichttp` and the address row's
  scope around `StatifierRouter.Delivery.deliver_event/4`, after the
  private `resolve/2` has resolved the token.
- The doors left unwrapped: `StatifierRouter.Delivery` never calls it,
  and `StatifierRouter.SendHandler`'s `perform/2` and private
  `deliver_to/5` call `deliver_event/4` without it; `deliver_event/4`
  opens its own transaction through the private `settled/5`. Wrapping
  the execution target where no wrapper reaches it stays undecided, as
  the Amendment says.
- The documentation: `StatifierRouter.Config`'s "Wrapping a whole
  delivery" and the README's "Wrapping a whole delivery" each say that a
  wrapper which opens a transaction on the configuration's repo makes
  every delivery of one `route/3` call commit or roll back together.
- The tests: `test/statifier_router/around_delivery_test.exs` covers each
  case the Amendment lists, under the describe blocks "the option", "a
  configuration without the option", "the :route door", "the Broadway
  handler and its partitioner", "the BasicHTTP front", "the
  execution-target door is not wrapped" and "the wrapper's contract".

## Amendment (2026-10-04): the whole-delivery wrapper may also enclose the execution target's delivery, opt-in

Status: accepted

The Amendment of 2026-10-02 left the execution target unwrapped on two
shapes, a live session on the send-processor shape and a step the router
did not drive, and ended its per-shape table with "Wrapping it on the
shapes where no wrapper reaches is not decided here." This Amendment
decides it. Its direction was ruled by the operator, 2026-10-03: the
wrapper also encloses the execution target's delivery on those two
shapes, as an opt-in addition, and a host that does not opt in sees the
published behaviour unchanged. Its spelling, one boolean key and one door
atom, was decided by the conductor under a standing consent, 2026-10-03.

**The superseded sentence.** "Wrapping it on the shapes where no wrapper
reaches is not decided here", in the Amendment of 2026-10-02, is
superseded by this Amendment. With the new key left out, or `false`,
every other sentence of that Amendment stands and each of its tables
answers as it did. With `wrap_target: true`, the sentences that say the
execution target has no door or is not wrapped - "the execution-target
door is not wrapped" in its opening paragraph, its doors table's "no
door of its own" and "no" for the execution target at the executor seam
and on the send-processor shape, and "The door is not wrapped." opening
its per-shape paragraph - hold only for a send whose delivery runs
inside a step a door drove; on the two shapes no door reaches, the
execution target has the door `:target` and is wrapped, as the table
below says.

- **The option.** `StatifierRouter.Config` takes one optional key,
  `:wrap_target`, a boolean defaulting to `false`. It names a door handed
  to `:around_delivery` and nothing else, so it is taken only beside an
  `:around_delivery`: a value that is not a boolean is refused with
  `{:error, {:invalid_value, :wrap_target, value}}`, and the key given
  without the wrapper, `false` included, with
  `{:error, {:missing_key, :around_delivery}}`.
- **The door.** One door atom is added, `:target`. The wrapper's
  contract is the one the Amendment of 2026-10-02 states: handed
  `(scope, :target, work)`, it calls `work` exactly once and answers what
  `work` answered.
- **Absent is today.** With the key left out, or `false`, the execution
  target is delivered as before: the same statements, in the same order,
  and the same answers.

**What `:target` covers.** A send to the execution target reads the
sender's address row first, because the scope is that row's. With
`wrap_target: true` and no door's work running, everything after that
read runs inside one call of the wrapper, handed the row's scope: the
send's delivery through `StatifierRouter.Delivery.deliver_event/4`, or
the `send_refused` row of a send the envelope checks refuse. The address
read stays outside, as the BasicHTTP front's token lookup does. A sender
with no address row has no scope, is refused as `unaddressed_sender`
with no row written, and reaches no call. A delayed send to the reserved
name is refused before any of this, and its `send_refused` row is written
outside the wrapper, as an unregistered route's is.

**How a wrapped step is told apart.** The doors mark their work while it
runs. On a configuration that sets `:wrap_target`, the work every door
hands the wrapper carries a mark for as long as it runs, set inside the
work, so it lives in the process the wrapper runs the work in, and put
back to what it was on every way out. A send to the execution target
whose delivery finds the mark is inside a step a door drove, and runs
directly; one that finds none is wrapped under `:target`, and its own
work carries the mark in turn, so a send its delivery's step makes is
wrapped once too. The mark is not a counter in the calling process: the
Amendment of 2026-10-02 avoided one because a wrapper may run the work in
another process, and the mark lives where the work runs.

**The execution target, per shape, with the opted-in answer.** The table
of the Amendment of 2026-10-02 gains a column:

| The sending step was driven by | Left out, or `false` | `wrap_target: true` |
|---|---|---|
| a wrapped door: a binding's delivery through `route/3`, or the BasicHTTP front | yes, by the sender's door, in the sender's context | yes, once, by the sender's door: the mark is found and no `:target` call is made |
| a step the router did not drive: a delayed event a timer job steps in, or a step the host makes itself | no | yes: one `:target` call, handed the sender's address row's scope, inside the sending step's transaction |
| a live session on the send-processor shape (`SendHandler.perform/2`) | no | yes: one `:target` call, handed the sender's address row's scope; `deliver_event/4` opens the transaction inside it |

**What the mark cannot tell apart.** The mark is this package's own, so
it tells a step a door of this package drove from every other step, and
nothing finer. A step the host runs inside its own context, at its own
call - its own wrap around a timer job's step, say - carries no mark, and
is one the router cannot tell from a step nobody wrapped: with
`wrap_target: true` the wrapper is called under `:target` there too,
inside the host's context, and must allow being entered while its context
is already set. This is stated rather than forced: the router has no way
to see a context it did not set.

**At the executor seam the work runs inside a transaction.** On a step
the router did not drive, the `:target` call is made inside the sending
step's transaction, so the wrapper must run `work` in the calling process,
and a transaction the wrapper opens there nests into the sender's: a
`c:Ecto.Repo.rollback/1` from it takes the sending step down, which
`StatifierRouter.Delivery.deliver_event/4`'s savepoint was put there to
prevent. A wrapper that opens a transaction of its own suits the
send-processor shape and the doors of the Amendment of 2026-10-02; on a
step the router did not drive it suits a wrapper that sets a context and
calls `work`.

**The doors left as they were.** `StatifierRouter.Delivery.deliver/4`
and `deliver_event/4` called by a host itself, `subscribe/3`, `cancel/2`,
`StatifierRouter.BasicHTTP.rotate_location/2` and the two reapers are not
wrapped under either setting; the host wraps them at the call. The
`:partition` door makes no send, so `:wrap_target` adds no call to the
Broadway pipeline.

**Where the code is.** In the pull request that carries this Amendment:
`StatifierRouter.Config`'s `new/1` checks the key with its private
`wrap_target/2`; its package-internal `around_target/3` makes the
`:target` call or runs the work, and its package-internal
`around_delivery/4` marks a door's work through its private `in_door/3`;
`StatifierRouter.SendHandler`'s private `to_execution/3` calls
`around_target/3` after the sender's address row is read. The anchors
that predate this Amendment were read at `3b56f22`:
`StatifierRouter.SendHandler`'s `perform/2` and private `deliver_to/5`,
`StatifierRouter.Delivery`'s `deliver_event/4`, and the private
`deliver/5` of `StatifierRouter.BasicHTTP.Front`. The tests are in
`test/statifier_router/around_delivery_test.exs`, under the describe
block "the execution-target door, opted in with :wrap_target": the
option's shape, the wrapped answer on the send-processor shape and on a
step the host makes itself, each with every statement of the target's
delivery run in the context the wrapper set, the delivery wrapped once
inside a step the `:route` door and the `:basichttp` door drive, and the
statements a configuration without the key issues on both shapes,
captured before the key existed. The describe block "the
execution-target door is not wrapped" is unchanged and stays green.

## Note (2026-10-04): a wrapper that calls its work twice has routed twice, and the extra call's effects stand

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. It states a consequence of the contract the
Amendment of 2026-10-02 sets out, which says that a wrapper that "calls
it twice raises `ArgumentError` once it returns" and does not say what
the second call has done by then.

The raise comes after the wrapper has returned, so it undoes nothing:
what every call of `work` wrote stands, and a wrapper that ran the work
inside a transaction of its own has committed it by then. On the
`:route` door a second call routes the event a second time. Each
binding's second delivery finds its dedupe claim of section 6 already
taken and records a `duplicate` ledger row, and a `key_refused` row,
which `StatifierRouter.route/3` writes with no dedupe claim of its own
(its private `key_refused/5`), is written a second time. The check that
raises is the package-internal `StatifierRouter.Config.around_delivery/4`;
`StatifierRouter.Config`'s "Wrapping a whole delivery" says the same.

## Note (2026-10-04, sr-4emm): the execution-target wrap Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Records merge at proposed and are accepted
once their code has shipped in a published version and every claim they
make verifies against `main`; this flip was decided by the conductor
under a standing consent, 2026-10-04. The `## Amendment (2026-10-04)` on
the execution target's delivery is such a record: its `Status:` line
moved from `proposed` to `accepted`. Its code landed in PR 161
(`3ce250b`, with `5829841`, which scoped its superseded-sentence
paragraph before the merge) and shipped in statifier_router 0.11.0 (tag
`v0.11.0`, at `df7f009`, published on Hex 2026-10-05T04:02:16Z). The
record's own status on line 3 was already `accepted` and was not
touched, and the Note of 2026-10-04 after the Amendment carries no
status and does not flip.

Every claim was re-verified by anchor at `df7f009`, which is both the
tag and `main` at the time of the flip. Later changes touched files the
Amendment cites, and none changes a claim: PR 163 (`285a64c`, the Note
of 2026-10-04 above and its documentation and test), ADR-0002's
Amendment of 2026-10-04 (`deliver_event/4`'s `:run_in_scope`, which
`StatifierRouter.SendHandler` does not set and which wraps nothing), and
PR 171 (`f0d24a1`, the ownership lists, which now name `:wrap_target`).

- The option: `StatifierRouter.Config`'s `new/1` checks `:wrap_target`
  with its private `wrap_target/2`, after `:around_delivery`: left out
  it is `false`; a value that is not a boolean is
  `{:error, {:invalid_value, :wrap_target, value}}`; the key given
  without a wrapper, `false` included, is
  `{:error, {:missing_key, :around_delivery}}`.
- The door: `StatifierRouter.Config`'s `door` type carries `:target`,
  and the package-internal `around_target/3` hands it to the
  package-internal `around_delivery/4`, whose contract is the one the
  Amendment of 2026-10-02 states.
- The mark: `around_delivery/4`'s reported work runs through the private
  `in_door/3`, which, on a configuration that sets `:wrap_target`, puts
  the door under a process key inside the work and puts back the value it
  replaced on every way out; `around_target/3` runs the work directly
  when it finds the mark and wraps it under `:target` when it finds none,
  so the `:target` work carries the mark in turn. Without the key both
  run the work directly.
- What `:target` covers: `StatifierRouter.SendHandler`'s private
  `to_execution/3` reads the sender's row through
  `StatifierRouter.Addresses.by_execution/2` before the call and outside
  it, answers `{:error, {:send_refused, :unaddressed_sender}}` with no
  call for a sender with no row, and hands `around_target/3` the row's
  scope around the private `addressed/5`, which either delivers through
  the private `deliver_to/5` and `StatifierRouter.Delivery.deliver_event/4`
  or writes the `send_refused` row. A delayed send to the reserved name is
  refused by the private `enqueue/5`, which never reaches `to_execution/3`.
- The shapes: `handle_effect/3` at the executor seam and `perform/2`'s
  private `perform_send/4` on the send-processor shape both reach
  `to_execution/3`; `deliver_event/4` opens its transaction through the
  private `settled/5`, which nests inside a caller's.
- The doors left as they were: `StatifierRouter.Config.around_delivery/4`
  is called only by `StatifierRouter.route/3` (`:route`),
  `StatifierRouter.Broadway`'s private `bindings_for/2` (`:partition`),
  `StatifierRouter.BasicHTTP.Front`'s private `deliver/5` (`:basichttp`)
  and `around_target/3` (`:target`); `StatifierRouter.Delivery`,
  `subscribe/3`, `cancel/2`, `StatifierRouter.BasicHTTP.rotate_location/2`
  and the two reapers call neither function. `StatifierRouter.Broadway`'s
  moduledoc says `:wrap_target` adds no call to the pipeline.
- The tests: `test/statifier_router/around_delivery_test.exs`, under the
  describe block "the execution-target door, opted in with :wrap_target",
  covers the option's shape, one `:target` call on the send-processor
  shape and on a step the host makes itself with the target's statements
  under the wrapper's context, a refused send's `send_refused` row inside
  the call, the delivery wrapped once inside the `:route` and
  `:basichttp` doors, and a configuration without the key issuing the
  same statements on both shapes. The describe block "the
  execution-target door is not wrapped" is still there.

## Amendment (2026-10-08): a webhook request may leave out its raw body when it carries a non-empty provider id

Status: accepted

Section 6's bullet "A webhook's message id is the provider's" names two
sources for a webhook's message id: the provider's event id when the
provider sends one, and otherwise a hash of the verified request body.
`StatifierRouter.Webhook.handle/3`, which implements that bullet (the
Note of 2026-09-21 above), has required the body on every request, so a
front that hands over an id of its own as the provider id, such as the
id of a row in which it stored a post, has had to pass a body too even
though the provider id was always the one taken. This Amendment relaxes
that, as ruled by the operator, 2026-10-07: the body may be left out
when the provider id is a non-empty string.

- **The rule is unchanged.** The provider's event id still wins whenever
  it is a non-empty string, and otherwise the message id is the
  lowercase hex SHA-256 of the body. Both sources of section 6's bullet
  stand, and neither gains a third.
- **The body is required only when it is the source.** A request with no
  `:raw_body` key and a non-empty string `:provider_id` is routed with
  the provider id as its message id. A request with neither a binary
  `:raw_body` nor a non-empty string `:provider_id` is refused as
  `{:error, {:invalid_request, request}}`, so an id is always derivable.
- **A request that carries the body is answered as before.** Only the
  absent key counts as no body. A binary `:raw_body` takes the rule
  above whatever `:provider_id` holds, and a `:raw_body` of any other
  type, `nil` included, is refused whatever `:provider_id` holds,
  exactly as when the key was required.

| The request | Its answer |
|---|---|
| a binary `:raw_body`, a non-empty string `:provider_id` | routed; the provider id is the message id (as before) |
| a binary `:raw_body`, `:provider_id` absent, `nil`, `""` or not a string | routed; the body's SHA-256 is the message id (as before) |
| a `:raw_body` that is not a binary, `nil` included | `{:error, {:invalid_request, request}}` (as before) |
| no `:raw_body` key, a non-empty string `:provider_id` | routed; the provider id is the message id (new) |
| no `:raw_body` key, `:provider_id` absent, `nil`, `""` or not a string | `{:error, {:invalid_request, request}}` (as before) |

The request type and the "The request" and "The message id" sections of
`StatifierRouter.Webhook`'s module documentation say the same, and so
does Step 1 of the guide "How to take webhooks and form posts". The
private `message_id/1` in `lib/statifier_router/webhook.ex` decides which
source a request names, and the tests "a request carrying a binary raw
body is answered as before", "is the provider id alone when the request
carries no raw body" and "refuses a non-binary raw body, and no body
without a provider id" in `test/statifier_router/webhook_test.exs` pin
the table above row by row.

The dedupe key is unchanged too: it is the binding and the message id
(section 6's first bullet), and a provider id carries no scope, so the
same provider id under two scopes through one shared binding is one
message whether or not the request carried a body.

## Note (2026-10-09): the tests that pin the raw-body Amendment's table, and a stored row's id as the provider id

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. The Amendment of 2026-10-08 closes by naming
three tests that "pin the table above row by row"; this Note gives the
whole list, and points a front that hands over a stored row's id as the
provider id at the guide step that already says where its dedupe starts.

- **The tests, row by row.** Every one is in
  `test/statifier_router/webhook_test.exs`. The ones the Amendment does
  not name are "is the provider's event id when it sends a non-empty
  one", "falls to the lowercase hex SHA-256 of the raw body when it does
  not", "two identical bodies are one delivery and one duplicate" and
  "refuses a request it cannot build an event from, and routes nothing";
  of these, "falls to the lowercase hex SHA-256 of the raw body
  when it does not" is the only test that sends a binary body with no
  `:provider_id` key.
  - A binary `:raw_body` with a non-empty string `:provider_id`: "is the
    provider's event id when it sends a non-empty one" and "a request
    carrying a binary raw body is answered as before".
  - A binary `:raw_body` with `:provider_id` absent, `nil`, `""` or not a
    string: "falls to the lowercase hex SHA-256 of the raw body when it
    does not" (`nil`, `""` and the key left out), "a request carrying a
    binary raw body is answered as before" (`nil`, `""` and an integer),
    and "two identical bodies are one delivery and one duplicate" (`nil`,
    with the ledger's message ids the digests of the two bodies it
    posts).
  - A `:raw_body` that is not a binary: "refuses a non-binary raw body,
    and no body without a provider id", with a `nil` and an integer body,
    each beside a non-empty string `:provider_id`, the one case in which
    the relaxation could have changed the answer. No test sends a
    non-binary body with any other `:provider_id`; that refusal is the
    private `message_id/1`'s clause for a `:raw_body` that is not a
    binary, which reads no provider id.
  - No `:raw_body` key with a non-empty string `:provider_id`: "is the
    provider id alone when the request carries no raw body".
  - No `:raw_body` key with `:provider_id` absent, `nil`, `""` or not a
    string: "refuses a non-binary raw body, and no body without a
    provider id", and "refuses a request it cannot build an event from,
    and routes nothing" with `nil`.
- **A stored row's id as the provider id.** The Amendment's example of a
  front that hands over an id of its own is "the id of a row in which it
  stored a post". Such an id names the row, not the post: a second post
  of the same submission, a provider's retry or a person's second click,
  stored as a new row, carries a new id, and the router's dedupe on the
  binding and the message id (section 6's first bullet;
  `StatifierRouter.Dedupe.claim/4`) takes it for a new message. The guide
  "How to take webhooks and form posts", in "Step 5. A form post you
  store first", says so in its paragraph "Two dedupe layers, the host's
  first": the host's unique index on the form's one-time token is the
  first layer and the router's claim the second, so a front that passes
  its stored row's id dedupes when it stores. That step landed in PR 182
  (`a74f1f4`) and shipped in statifier_router 0.12.0 with the
  Amendment's code.

## Note (2026-10-09, sr-7rqa): the raw-body Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Records merge at proposed and are accepted
once their code has shipped in a published version and every claim they
make verifies against `main`; this flip was decided by the conductor
under a standing consent, 2026-10-09. The `## Amendment (2026-10-08)` on
a webhook request without its raw body is such a record: its `Status:`
line moved from `proposed` to `accepted`. Its code landed in PR 181
(`04606a9`, with `95fb4dd`, which scoped the module documentation's
wrong-type sentence to the keys it checks before the merge) and shipped
in statifier_router 0.12.0 (tag `v0.12.0`, at `cb83a13`, published on
Hex 2026-10-08T09:28:14Z by the release workflow's run
https://github.com/riddler/statifier_router/actions/runs/37756763701).
The record's own status on line 3 was already `accepted` and was not
touched, and the Note of 2026-10-09 above carries no status and does not
flip.

Every claim was re-verified by anchor at `cb83a13`, which is both the
tag and `main` at the time of the flip. One later change touched a file
the Amendment cites, and it changes no claim: PR 182 (`a74f1f4`), the
guide's Step 5, which the Note of 2026-10-09 above cites. The
Amendment's sentence that its three named tests pin the table row by
row is completed by that Note's list.

- The rule: `StatifierRouter.Webhook`'s private `message_id/2` answers
  the provider id when it is a non-empty string and otherwise the
  lowercase hex SHA-256 of the body, and has no third answer.
- The body only when it is the source: the private `message_id/1`'s
  clause for a request without `:raw_body` answers a non-empty string
  `:provider_id`, and its last clause answers `:error`, which the private
  `source_event/1` returns as `{:error, {:invalid_request, request}}`.
- A request that carries the body: `message_id/1`'s first clause hands a
  binary `:raw_body` to `message_id/2` whatever `:provider_id` holds, and
  its second refuses any other `:raw_body`, `nil` included, before a
  provider id is read.
- The documentation: the `request` type marks `:raw_body` optional; the
  module documentation's "The request" and "The message id" sections and
  the guide's "Step 1. Keep the raw body" state the same rule, the guide
  naming 0.12.0 as the version it starts in.
- The dedupe key: `StatifierRouter.Dedupe.claim/4` claims on the
  binding's id and the message id alone, so one provider id under two
  scopes through one binding is one message.
- The ruling: the relaxation was ruled by the operator, 2026-10-07, as
  the Amendment says.
- The tests: the ones the Note of 2026-10-09 above lists, in
  `test/statifier_router/webhook_test.exs`.
