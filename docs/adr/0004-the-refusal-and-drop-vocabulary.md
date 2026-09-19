# ADR-0004: The refusal and drop vocabulary: seven outcomes of one routing attempt, their spellings, where each is recorded, the ledger row, no_match left off the ledger, and what route/3 returns

Status: proposed

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
section 3 names, an execution that is already terminal when it is handed
the event.

### 3. A refusal or a drop never creates or touches an execution

For a refusal or a drop, the router creates no execution, steps none and
writes none, with the one exception named at the end of the next
paragraph, where the create came first. Every refusal, every duplicate
and dropped: no_execution is decided before any call to `create/4` or
`step/5`, because a called `create/4` fires its chart's initialize
effects whether or not it succeeds. The router decides
dropped: finished from the address row and the execution's status, and
steps nothing.

Two cases reach dropped: finished after a call has been made. When `step/5` answers `{:discarded,
execution}` because the execution became terminal after the router's
read, the outcome is dropped: finished and statifier_persistence's input
log carries nothing for it (sp-ADR-0010, section 5); whatever `step/5`
does with its own record in that case is statifier_persistence's. And
when an execution the router created for this event is already terminal
by the time `step/5` is handed the event (its chart finished while it was
initialized), the outcome is dropped: finished with that execution's id:
the create was the binding's to make, and the event did not reach it.

The one write a drop makes outside the ledger is the `terminal_seen_at`
stamp on the address row that ADR-0002, section 5 asks for, and that row
is the router's, not the execution's.

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
The ledger rows of delivered and created_and_delivered are written in the
delivery record's transaction, so they commit exactly when the input does;
the rows of every other outcome the ledger holds are written by the
evaluation that decides them. The ledger is not the dedupe table: which
table answers "already handled" is the delivery record's.

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
statifier_persistence door returning `{:error, reason}`, a lock wait
ending in a timeout. `route/3` returns `{:error, reason}` for it and writes
no ledger row for it. The first such error ends the attempt: the bindings
after it are not evaluated, and outcomes already committed for the
bindings before it stay committed. A front that receives `{:error, _}`
does not acknowledge the message, so the source hands it over again, and
the next attempt finds the bindings whose delivery committed as
duplicates (the delivery record's dedupe).

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
  carries a trace of an event that did not reach it.
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
