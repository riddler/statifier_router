# ADR-0004: The refusal and drop vocabulary: seven outcomes of one routing attempt, their spellings, where each is recorded, the ledger row, no_match left off the ledger, and what route/3 returns

Status: accepted

## Context

ADR-0001 decides that a binding's `match` can refuse, that its `key` can
refuse, and that every refusal is recorded against the binding and never
against an execution; it leaves the names of those records, and where they
live, to this record. ADR-0002 decides that a finished execution keeps its
address row for a horizon and that a late event for that address is a
recorded drop; it leaves the drop's name here too. The delivery record
decides how an event reaches an execution: the transaction, the race, the
create modes and deduplication. Each of those decisions ends in something
the host needs to see, and every later piece of code returns and records
it: the evaluation loop, the delivery transaction, the Broadway front, and
a webhook controller a host writes. They have to agree on one vocabulary.

The four nouns are used each for itself. A **document** is the stable thing
an author edits and names. A **revision** is one saved state of a document.
A **chart** is what a revision compiles to. An **execution** is one
durable, stepped instance of one chart.

Facts that bound the answer:

- **ADR-0001 fixes what refuses and what does not.** predicator returns its
  errors rather than raising them. A `match` holds only on exactly `true`;
  `false`, `nil` and `:undefined` all mean "not for this binding"; a
  `match` that returns an error, or evaluates to any other value, is a
  routing refusal. A `key` that is not a non-empty string, or whose
  evaluation returns an error, is a routing refusal. A duplicate binding
  `id` is a fault of the configuration, refused before any event is routed,
  so it is never the outcome of routing one event.
- **statifier_persistence writes an execution's input log in one place.**
  `StatifierPersistence.Executions.step/5` appends the event it stepped, and
  appends nothing for a delivery it discards, such as one to a terminal
  execution (sp-ADR-0010, section 5, "Seven doors, one write site, and only
  inputs the interpreter saw").
- **A create that is called has already acted.** `Executions.create/4`
  hands its chart's initialize effects to the executor before it writes the
  execution record, and a create refused with `{:error,
  :execution_exists}` has fired them too (statifier_persistence README,
  "Writing inside a caller's transaction", at statifier_persistence
  13fdb64).
- **Most bindings do not match most events.** One event is evaluated
  against every enabled binding for its source (ADR-0001, section 4), and
  sparse events are normal there, not errors. A host with N bindings on a
  source evaluates N matches per event, and usually one or two hold.

## Decision

### 1. The seven outcomes

One routing attempt of one event produces exactly one outcome for each
enabled binding whose `source` is the event's source. The outcomes are
exactly these, and the spelling in the second column is the term
`route/3` returns for it:

| Outcome | Returned as | Means | Recorded on |
|---|---|---|---|
| delivered | `{:delivered, binding_id, execution_id}` | the address resolved to an existing execution and `step/5` took the event | the execution's input log and the binding's ledger |
| created_and_delivered | `{:created_and_delivered, binding_id, execution_id}` | an execution was created under a newly minted id and `step/5` took the event | the execution's input log and the binding's ledger |
| duplicate | `{:duplicate, binding_id}` | the binding had already handled this message id within its dedupe horizon | the binding's ledger only |
| no_match | `{:no_match, binding_id}` | `match` evaluated to `false`, `nil` or `:undefined` | nowhere durable (section 5) |
| key_refused | `{:key_refused, binding_id, reason}` | `match` returned an error or a value other than `true`, `false`, `nil` or `:undefined`, or `match` held and `key` returned an error or a value that is not a non-empty string | the binding's ledger only |
| dropped: no_execution | `{:dropped, binding_id, :no_execution}` | the binding's `create` is `:never` and the address has no row | the binding's ledger only |
| dropped: finished | `{:dropped, binding_id, :finished}` | the execution the event was for is terminal, so the event did not reach it (section 3) | the binding's ledger only |

`binding_id` is the binding's `id` and `execution_id` is the id the router
minted for the execution (ADR-0002, section 3). `reason` in `key_refused`
names which program refused and how, as one of `{:match, {:error,
error}}`, `{:match, {:value, value}}`, `{:key, {:error, error}}` and
`{:key, {:value, value}}`, where `error` is what predicator returned and
`value` is what the program evaluated to. A click with no `impression_id`
is therefore `{:key_refused, "clicks_to_join", {:key, {:value,
:undefined}}}`.

`key_refused` covers a refusing `match` as well as a refusing `key`: both
mean that the binding produced no address for this event, and `reason`
tells them apart.

### 2. One outcome per binding, decided in a fixed order

For each binding, the outcome is the first of these that applies:
`match` does not hold or refuses (no_match or key_refused); `key` refuses
(key_refused); the binding already handled this message id within its
horizon (duplicate); the address and the binding's `create` decide the
rest. Given a binding that reaches the last step, the outcome is:

| `create` | The address has no row | The row's execution is active | The row's execution is terminal |
|---|---|---|---|
| `:if_absent` | created_and_delivered | delivered | dropped: finished |
| `:never` | dropped: no_execution | delivered | dropped: finished |
| `:always_new` | created_and_delivered | created_and_delivered | created_and_delivered |

An `:always_new` binding reads and writes no address row (ADR-0002,
section 7), so its three columns are one case: every delivery creates.
A created_and_delivered cell becomes dropped: finished in the one case
section 3 names, an execution that `create/4` returns already terminal.

### 3. For a refusal or a drop, the router itself never creates, steps or writes an execution, except the create that precedes a dropped: finished

For a refusal or a drop, the router itself never creates, steps or
writes an execution, with one exception: the create that precedes a
dropped: finished, named below. Its one other call into an execution for
a drop is the `step/5` whose `{:discarded, execution}` answer decides a
dropped: finished, also named below; what `step/5` writes then, such as
a repair of the execution's status, is statifier_persistence's, not the
router's.
Every refusal, every duplicate and dropped: no_execution is decided before
any call to `create/4` or `step/5`, because a called `create/4` fires its
chart's initialize effects whether or not it succeeds. The router reads
the status of the execution the address row names before it calls
`step/5`, and when that read finds the execution terminal, the outcome is
dropped: finished and nothing is stepped.

Two cases reach dropped: finished after a call has been made, and in
neither does the execution's input log receive the event. In the first,
`step/5` is called: it answers `{:discarded, execution}` because the
execution became terminal after the router's read, and that answer
decides the outcome. statifier_persistence's input log carries nothing for
a discarded delivery (sp-ADR-0010, section 5), and whatever `step/5` does
with its own record in that case is statifier_persistence's. In the
second, `create/4` is called, and this is the one exception: an execution
the router created for this event is already terminal when `create/4`
returns it (its chart finished while it was initialized), so it is not
stepped, and the outcome is dropped: finished with that execution's id.
The create was the binding's to make, and the event did not reach the
execution.

The writes a drop makes outside the ledger are the router's own: the
dedupe row the delivery record defines, and the `terminal_seen_at` stamp
on the address row that ADR-0002, section 5 asks for. Neither is the
execution's.

### 4. The ledger

The binding's **ledger** is one table, `routing_ledger`, shared by every
binding and read per binding. Its row:

| Column | Holds |
|---|---|
| `binding_id` | the binding's `id` |
| `message_id` | the id of the message the attempt routed |
| `scope` | the host's scope for the event (ADR-0002, section 2) |
| `outcome` | any outcome of section 1 other than no_match, spelled as in that table's first column |
| `key` | the key the binding produced; empty for key_refused |
| `execution_id` | the execution the outcome names; empty for duplicate, key_refused and dropped: no_execution |
| `reason` | for key_refused, the reason term of section 1; empty otherwise |
| `inserted_at` | when the row was written |

`scope` and `key` are on the row because a host reads its ledger per scope
and asks which key an outcome was for; `binding_id`, `message_id`,
`outcome`, `execution_id`, `reason` and `inserted_at` are the row's
substance. The encoding of `reason` in the column, the migration that
creates the table, and any index on it are the code half's.

The ledger is append-only: one row per recorded outcome per attempt, never
updated. A front that hands the router the same message again makes a
second attempt, and the second attempt's outcomes are rows of their own;
for a binding that delivered the first time, that row is a duplicate.
The ledger row of every outcome decided inside the delivery record's
transaction commits with that transaction, so a delivered or
created_and_delivered row commits exactly when the input does; a
key_refused row, decided before any delivery, is written on its own. The
ledger is not the dedupe table: which table answers "already handled" is
the delivery record's.

### 5. no_match is returned and counted, never written as a row

A no_match writes no ledger row and no counter row. It is returned by
`route/3`, and it is reported as a telemetry event the host may count; the
event's name is the code half's.

The reason is the cost. Every event is evaluated against every enabled
binding for its source, so with N bindings on a source and one or two
holding, a row per no_match is N minus one or two writes per event, each
recording that a binding did not apply, and the ledger would become
mostly a list of events that were never for the binding. A durable per-binding counter is cheaper in rows but not in
contention: every event on a source would update the same N counter rows,
so every concurrent processor on that source would queue on them. A
no_match is not a fault, and a host that wants its rate has it from
telemetry without the router writing anything. Every other outcome is either a delivery, a
fault the host must be able to find (key_refused), or a message that
arrived and did not land (duplicate, the two drops), and those are the
rows.

### 6. What route/3 returns

`route/3` returns `{:ok, outcomes}`, where `outcomes` is a list with one
outcome per enabled binding whose `source` is the event's source, in the
order the host's configuration lists those bindings. An event no enabled
binding is for returns `{:ok, []}`. A binding whose `enabled` is `false`
contributes nothing, and a binding for another source contributes nothing.
The Broadway front and a host's webhook controller both read this one
shape.

### 7. An error is not an outcome

A failure that is not about the event and the binding is not an outcome:
the host's chart resolver failing, the Repo unavailable, a
statifier_persistence door returning `{:error, reason}`. `route/3` returns `{:error, reason}` for it and writes
no ledger row for it. The first such error ends the attempt: the bindings
after it are not evaluated, and outcomes already committed for the
bindings before it stay committed. A front that receives `{:error, _}`
does not acknowledge the message, so the source hands it over again, and
the next attempt finds the bindings whose delivery committed as
duplicates (the delivery record's dedupe). A raise inside a delivery,
such as a lock wait ended by a timeout, is not an outcome either, and
what it does is the delivery record's to decide.

### 8. unmatched_event is out of this release

An event the execution's current state has no transition for is not a
drop in this release. `step/5` takes it, and the router records it as
delivered or created_and_delivered. Naming it (a `dropped: unmatched_event`
outcome) needs the router to ask the chart what its current state
accepts, and that is out of this release; a later record may add it.

### The example: an impression, its click, and what the ledger holds

The two bindings of ADR-0001's example, `impressions_to_join` and
`clicks_to_join`, both take the defaults: `create: :if_absent` and a
72-hour horizon. Under the host's scope `"7c1e"`, the source `ad_events`
hands the router these messages, with message ids its adapter derived:

1. `ad_events/3/1042`, an impression of `imp_7f3a`.
   `route/3` returns `{:ok, [{:created_and_delivered, "impressions_to_join",
   "ex_9k2q"}, {:no_match, "clicks_to_join"}]}`.
2. `ad_events/3/1107`, a click on `imp_7f3a`. It returns `{:ok,
   [{:no_match, "impressions_to_join"}, {:delivered, "clicks_to_join",
   "ex_9k2q"}]}`.
3. `ad_events/3/1107` again, after the front failed to acknowledge it. It
   returns `{:ok, [{:no_match, "impressions_to_join"}, {:duplicate,
   "clicks_to_join"}]}`.
4. `ad_events/5/0388`, a click with no `impression_id`. It returns `{:ok,
   [{:no_match, "impressions_to_join"}, {:key_refused, "clicks_to_join",
   {:key, {:value, :undefined}}}]}`.
5. `ad_events/3/1311`, a second click on `imp_7f3a`, arriving after
   `ex_9k2q` completed and within the horizon. It returns `{:ok,
   [{:no_match, "impressions_to_join"}, {:dropped, "clicks_to_join",
   :finished}]}`.

The ledger then holds five rows, one for each outcome above that is not a
no_match:

| `binding_id` | `message_id` | `scope` | `outcome` | `key` | `execution_id` | `reason` |
|---|---|---|---|---|---|---|
| `impressions_to_join` | `ad_events/3/1042` | `7c1e` | created_and_delivered | `imp_7f3a` | `ex_9k2q` | |
| `clicks_to_join` | `ad_events/3/1107` | `7c1e` | delivered | `imp_7f3a` | `ex_9k2q` | |
| `clicks_to_join` | `ad_events/3/1107` | `7c1e` | duplicate | `imp_7f3a` | | |
| `clicks_to_join` | `ad_events/5/0388` | `7c1e` | key_refused | | | `{:key, {:value, :undefined}}` |
| `clicks_to_join` | `ad_events/3/1311` | `7c1e` | dropped: finished | `imp_7f3a` | `ex_9k2q` | |

The input log of `ex_9k2q` holds two events, the impression and the first
click: the duplicate, the refusal and the drop never reached it.

## Consequences

- One vocabulary reaches every caller: the evaluation loop, the delivery
  transaction, the Broadway front and a webhook controller all speak the
  seven tuples of section 1, and nothing downstream has to reinterpret a
  result.
- Everything that did not land is findable per binding. A host asking why
  an event did not reach an execution reads the binding's ledger and finds
  a duplicate, a refusal with its reason, or a drop; an execution never
  carries a trace of an event that did not reach it. The one execution a
  drop can leave behind is the exception of section 3, one created for the
  event that was already terminal when `create/4` returned it, and its
  input log does not hold the event.
- A no_match leaves no durable trace. A host that needs to know how often
  a binding did not apply counts the telemetry event; a host that needs to
  know that a particular event matched no binding at all reads the `{:ok,
  outcomes}` it was handed. The ledger stays proportional to what landed
  or was refused, not to the number of bindings.
- A retry is safe to hand back. Because an error ends the attempt without
  undoing what committed, and a front that sees `{:error, _}` does not
  acknowledge, the source's redelivery is a new attempt in which the
  bindings that delivered read as duplicates; the ledger shows both
  attempts.
- `key_refused` names a refusing `match` as well as a refusing `key`, so
  a host filtering its ledger for key faults also sees match faults; the
  `reason` term separates them.
- An event the chart ignores reads as delivered. Until a later record adds
  `dropped: unmatched_event`, the ledger does not distinguish an event
  that moved the execution from one its current state had no transition
  for.
- This record leaves to the delivery record: the transaction, the race
  between two first events, the create modes and the dedupe table; and to
  the code half: the ledger's migration, the encoding of `reason`, and the
  telemetry event's name.

## Note (2026-09-22, sr-nyl): accepted

This record's status was flipped from proposed to accepted on the
operator's word, after statifier_router 0.2.0 was published. The Note
decides nothing and changes no decision above it.

Every claim this record makes about the code half was verified against
`main` at `251abb7` before the flip: the seven outcome tuples and the
`reason` term (`StatifierRouter`'s `@type outcome` and
`@type refusal_reason`); the fixed order match, key, duplicate, then the
address and `create` (`StatifierRouter.route_binding/4` and
`StatifierRouter.Delivery.claimed/4`); the drop that follows a
`{:discarded, execution}` answer and the `terminal_seen_at` stamp
(`StatifierRouter.Delivery.finished/6`); the ledger's eight columns and
its per-binding index (`StatifierRouter.Migrations.V01.up/1` and
`StatifierRouter.Schema.Ledger`); a no_match writing no row and reporting
telemetry instead (`StatifierRouter.no_match/2`); and the shape `route/3`
returns, including the first delivery error ending the attempt
(`StatifierRouter.route/3`).

Section 8 holds as written: nothing in the package names
`dropped: unmatched_event`, and its sentence "a later record may add it"
is the only sentence above that speaks of what this release does rather
than of what the vocabulary is. It is met, not edited: the outcome is
still deferred, and `sr-020` carries it.

Section 4's reading of the ledger's `key`, `execution_id` and `reason`
columns is the inbound-routing reading. ADR-0006, section 6 adds the
`send_refused` outcome for a send this package refuses and gives a table
of what each of its reasons leaves empty; ADR-0006's Consequences say
that section 4 is where a reader learns the older reading. No column's
shape changes and no row already written reads differently, so this
record is accepted as it stands and ADR-0006 is the forward pointer a
reader reaching this record first should follow for the outbound case.

The status cell for this record in `docs/adr/README.md` still reads
proposed; it is flipped for all seven records together in a later bead,
so the index lags this file by design until then.

## Note (2026-09-22, sr-3cp): where each refusal and drop's publish-time twin is listed

This Note points a reader at a table that now exists outside this
repository. It decides nothing, and no line above it was edited.

The engine repository keeps one page listing every refusal the family
raises at run time beside the publish-time function that finds the same
defect first, its twin, or the word NONE where no function does:
`docs/publish-time-checks.md` in statifier-ex, read at `018ec64`. Its
`statifier_router` section gives each refusal and drop this record
names a row, citing this record by path:

- key_refused (section 1): NONE, because `match` and `key` read the
  event's payload.
- dropped: no_execution (sections 1 and 2): NONE.
- dropped: finished (sections 1 and 3): NONE.
- The deferred `dropped: unmatched_event` (section 8): its row says an
  event the receiving chart never listens for is not refused today, and
  names as its twin `StatifierRouter.Contracts.check/3`, which falls
  back to `Statifier.Chart.check_accepts/2` for a receiver that declares
  nothing.

Section 7 counts the host's chart resolver failing as an error that is
not an outcome, and the page does not give every such error NONE. When
the failure is a resolver with no published chart for the document a
binding or a literal `document` param names, the page's row names a
twin: `StatifierRouter.Contracts.check/3`, with reason `:not_published`
(ADR-0008, decision 4). The rows that cite section 7 themselves each
carry NONE: the configured `:on_complete` route failing, a chart
resolver with no chart for the content hash an existing execution
started on, a malformed message or options handed to `route/3`, and a
persistence step's error. duplicate and no_match are neither a refusal
nor a drop here (sections 3 and 5), and the page gives them no row.

**The deferred drop's twin is the receiver contract at publish.**
At publish, ADR-0008 checks against the receiving document the event of
every binding, and the event of an execution-target send when that event
is a static name and the send's `document` param is literal (decision
1). A send it selects but cannot judge, such as one with a literal event
and a non-literal or missing `document`, is reported unchecked (decision
3). The package's composed check is
`StatifierRouter.Contracts.check/3` (`lib/statifier_router/contracts.ex`,
read at `d0202b2`), which reports those findings under
`undeclared_events` and `undeclared_binding_events` and leaves to the
host which of them blocks a publish (ADR-0008, decision 6).

**When a drop of a literal event name would be a bug in a publish check.**
The page opens on the rule that a runtime refusal for something a literal
in the source could have told us is a bug in the publish check. For this
record's deferred drop, ADR-0008, decision 5 says when that holds: once
`dropped: unmatched_event` exists, a drop of a literal name that no
reachable transition of the receiver's chart matches, sent by a send or a
binding the check passed, means a publish check has a bug - that check,
or the receiver's own check of its declaration - only when the execution
is stepped on the revision the check judged, in the scope it judged, and
the host refuses a publish on `unreachable`. Revision drift, host policy
and scope are the three cases decision 5 names where it does not. A drop
of a name the check reported unchecked, such as an `eventexpr`, is the
gap ADR-0008, decision 3 already names.

Section 8 holds as written: the outcome is still deferred, and nothing
under `lib/` produces it at `d0202b2`.

## Note (2026-09-23, sr-p1e): a raise from the key_refused row's own write propagates

This Note says what happens when the one ledger write this package makes
outside a delivery fails. It decides nothing new, and no line above it
was edited.

Section 7 lists the Repo unavailable among the failures that are not an
outcome, and says `route/3` returns `{:error, reason}` for it. Inside a
delivery that holds only for an `{:error, reason}` the repo returns:
ADR-0003, section 1 says an error returned there rolls the delivery back
and is `route/3`'s `{:error, reason}`, while a Repo failure that raises
there, such as a dropped connection or a lock wait ended by a timeout,
rolls the delivery back and propagates to `route/3`'s caller unrescued.
The key_refused row is outside any delivery. Section 4 says
that row, decided before any delivery, is written on its own, and it is
written with a bang insert (`StatifierRouter.key_refused/5`, read at
`c0753db`). A Repo failure on that write raises; `route/3` does not
rescue it, so the raise propagates to `route/3`'s caller rather than
becoming `{:error, reason}`, and no key_refused row is left behind.

ADR-0003, section 1 decides that `route/3` does not rescue, but its words
are about a raise inside a delivery. The same rule reaches this write:
nothing between it and `route/3`'s caller rescues, and a front treats
this raise as ADR-0003, section 1 says it treats any other: it does not
acknowledge the message, and the source hands it over again. The test
"a raise from the key_refused ledger write propagates out of route/3"
(`test/statifier_router/route_test.exs`, added with this Note) pins it.

## Note (2026-09-25, sr-020): dropped: unmatched_event is recorded, and what it cannot tell apart

This Note says what the outcome section 8 deferred means now that the
package records it. It reopens no decision above it, and no line above it
was edited.

**What changed underneath.** Section 8 deferred the outcome because
naming it needed the router to ask the chart what its current state
accepts. It no longer needs that question. statifier 2.9.0 stamps the
round's selection on the state it answers:
`Statifier.Interpreter.handle_event/2` sets the state's `last_selection`
to `:selected` when the delivered event selected at least one transition
and to `:none` when it selected none, whether or not tracing is on
(`t:Statifier.MachineState.last_selection/0`). statifier_persistence
0.18.0's `StatifierPersistence.Executions.step/5` answers
`{:ok, execution, state}` with that stepped state, and nothing in its
drive after the round writes `last_selection`, so the router reads the
answer it already holds and asks the chart nothing.

**What the outcome means.** `{:dropped, binding_id, :unmatched_event}`,
recorded on the binding's ledger as `dropped: unmatched_event`, means
this delivery moved nothing: `step/5` took the event, and the event
selected no transition in the execution's current configuration. It is
decided after the step, on the answer's `last_selection` of `:none`, on
both paths that step: an execution that existed, and an execution this
delivery created and then stepped (`StatifierRouter.Delivery`, added
with this Note). Its ledger row carries the key and the execution's id.
It is the one drop whose event did reach the execution: `step/5`
appended it to the input log before answering, so the input log holds
the event, as it does for a delivery. A `last_selection` of `nil` means
no round ran on this event, not that none matched, and keeps delivered
or created_and_delivered. The ledger's `outcome` column is unconstrained
text (`StatifierRouter.Migrations.V01.up/1`), so the new spelling needs
no migration.

**What it cannot tell apart, and why.** It does not mean "the chart can
never take this event". `last_selection` is two-valued: it says whether
any transition was selected for the event, not why none was. An event no
transition of the current state names, an event whose every candidate
transition had a false guard, and an event another state of the same
chart would take all read `:none`, and so all record `dropped:
unmatched_event`. Telling them apart needs an event vocabulary on the
engine side, one the chart can be asked of; until one exists, a host
that needs to know whether a name can ever be taken asks the publish
check ADR-0008 describes.

**Where it does not reach.** The outcome is `route/3`'s. An
execution-to-execution send, delivered through
`StatifierRouter.Delivery.deliver_event/4`, keeps the outcomes ADR-0006
gives it: a send the receiving execution does not take is still
delivered or created_and_delivered, and the sender is told nothing new.
ADR-0008, decision 5's first bullet, "An event the receiver's chart
never takes is not refused", therefore still holds for a send and no
longer for a binding.

Section 1's table and section 2's cells are read with this row beside
them: where a binding's step selects no transition, a delivered or
created_and_delivered cell records dropped: unmatched_event instead.
Section 8's "a later record may add it" is met by this Note, and the
Consequence "An event the chart ignores reads as delivered" no longer
holds for a binding.
