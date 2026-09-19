# ADR-0002: Addressing: one table from (scope, document, key) to an execution id the router mints, scope an opaque host string, the host's chart resolver, a row that outlives its execution for the longest dedupe horizon, reaping as a plain function, and no row for always_new

Status: proposed

## Context

ADR-0001 gives every binding a `document` and a `key` program, and a key
that evaluates to a non-empty string. What it leaves open is the step
after: given a document and a key, which execution is it? The answer has to
be durable (an impression and the click that follows it can arrive days
apart, in different processes), unique (two first events for one key must
not open two executions), and cheap to ask.

The four nouns are used each for itself. A **document** is the stable thing
an author edits and names. A **revision** is one saved state of a document.
A **chart** is what a revision compiles to. An **execution** is one
durable, stepped instance of one chart.

Facts outside this package that bound the answer:

- **statifier_persistence takes the execution id from its caller.**
  `StatifierPersistence.Executions.create/4` takes the id as an argument,
  and `StatifierPersistence.Storage.Adapter`'s `execution_id` type is "a
  caller-supplied opaque string, stored verbatim", never a surrogate that
  package generates (both read at statifier_persistence 2e25130). Someone
  above the store has to mint it.
- **statifier_persistence records a status, not when it changed.**
  `StatifierPersistence.Storage.fetch_execution/2` returns a record whose
  `status` is `:active`, `:completed`, `:failed` or `:cancelled`, the last
  three terminal; the record carries no time of the transition (read at
  2e25130).
- **No package in the family stores which revision of a document is
  active.** Neither this package nor statifier_persistence keeps a publish
  store, so the chart a new execution starts on has to come from the host.
- **Hosts partition their documents and executions in their own ways.**
  This package has to keep those partitions apart without knowing what any
  of them is.

## Decision

### 1. One table, the address

There is one table, the **address**: `(scope, document, key)` ->
`execution_id`, with a unique index on `(scope, document, key)`. Its
columns:

| Column | Holds |
|---|---|
| `scope` | the opaque host string of section 2 |
| `document` | the binding's `document`: the stable document id |
| `key` | the string the binding's `key` program produced (ADR-0001, section 3) |
| `execution_id` | the id the router minted for the execution (section 3) |
| `inserted_at` | when the row was written |
| `terminal_seen_at` | when this package first saw the execution terminal (section 5); empty until then |

The middle term is the stable **document** id, never a chart hash: a
document has revisions, a revision compiles to a chart, and an execution
runs one chart, so an address that named a chart would send the next event
for a key to a different execution each time the document gained a
revision. The table is named `addresses`; the migrations that create it,
and the table prefix a host may set, are the code half's. No index beyond
the unique one is decided here.

### 2. scope is an opaque host string

`scope` is a string the host supplies with each event it hands the router;
a binding carries none. The package never says what a scope means, compares
it only for equality, and gives it no structure: two events with equal
scopes, documents and keys share an execution, and any difference in scope
keeps them apart. The word is `scope` in every column, function and
piece of documentation in this package. How the scope rides with an event
is the delivery record's.

### 3. The router mints the execution id

When get-or-create finds no row, the **router** mints a new, opaque
execution id, passes it to `StatifierPersistence.Executions.create/4`, and
writes that id into the address row. The id is never derived from the key,
the document, the scope or any other part of the address: two executions
that ever held the same address, one after another, have unrelated ids, and
nothing may read meaning into an id. The id's format is the code half's. A
reader asking who mints an execution id gets the router; statifier_persistence
stores what it is handed.

### 4. The host resolves a document to its chart

Which chart a new execution starts on is the **host's** answer. The host
supplies a resolver callback that takes `(scope, document)` and returns
`{content_hash, machine}`: the content hash and the compiled machine of the
chart that new executions of that document start on. The router calls it
only when it is about to create an execution. An existing execution keeps
the chart it started on; a new revision of a document changes where new
executions start, never where an addressed one is.

### 5. The row outlives its execution

A finished execution keeps its address row for the **longest dedupe
horizon of any enabled binding naming its document**. For that long, a late
event for its address resolves to the finished execution and is recorded
as a drop; it never opens a fresh execution under `if_absent`. The horizon
is counted from `terminal_seen_at`: the first time this package reads the
execution's status as terminal, whether at a delivery or during a reap, it
stamps that time on the row. Because that stamp is never earlier than the
true transition, the row is kept at least as long as the rule asks. The
recorded drop's name is the outcome-vocabulary record's.

### 6. Reaping is a plain function the host schedules

Rows are removed by `reap/2`, a plain function that takes the storage it
works on and the host's current bindings. It reads the status of the
execution behind each candidate row, stamps `terminal_seen_at` on rows whose
execution is terminal and not yet stamped, and deletes the rows whose
execution is terminal and whose horizon has elapsed since
`terminal_seen_at`. The horizon is computed from the bindings passed in, at
reap time, so a host that shortens or lengthens a binding's horizon changes
retention at the next reap; a document no enabled binding names has a
horizon of zero. `reap/2` deletes address rows only: it never deletes,
alters or steps an execution. This package runs no process to call it; the
host schedules it.

### 7. always_new writes no address row

A delivery through a binding whose `create` is `always_new` creates an
execution under a freshly minted id and writes **no address row**. The
minted id is the only handle on that execution. The binding's `key` is
still evaluated and still refused as ADR-0001, section 3 says, but it
addresses nothing. Two reasons decide it:

- An address exists so that a later event with the same key reaches the
  same execution. Under `always_new` no later event ever does, by
  definition: every delivery creates. A row would be a write per event that
  nothing in this release reads.
- The other candidate, a row whose `key` column holds the minted id, puts
  in the `key` column a value no binding's `key` program produced. That
  breaks ADR-0001's rule that the router never invents a key, and it would
  leave the unique index guarding a value that can never collide.

A later reader that needs to reach an `always_new` execution reaches it by
its execution id, which is how statifier_persistence already addresses
every execution.

### 8. Who writes and who reads

The address table is written in two places only: by get-or-create, inside
the delivery record's transaction, which inserts rows and stamps
`terminal_seen_at` when a delivery finds the execution terminal; and by
`reap/2`, which stamps and deletes. It is read by every resolver of an
address. In this release the only resolver is delivery from a binding.
Sinks, timers and execution-to-execution sends are its named **future**
readers, and none of them is in this release.

### The example

The two bindings of ADR-0001's example both name the document
`impression_click_join` and key on `event.impression_id`. With the host's
scope `"7c1e"`, the first event for impression `"imp_7f3a"`, an
impression or a click, finds no row for `("7c1e",
"impression_click_join", "imp_7f3a")`. The router asks the host's resolver
for the chart of `("7c1e", "impression_click_join")`, mints an execution
id, creates the execution under it, and writes the row. Every later event
for that impression, of either kind, resolves through the row to the same
execution. The same impression id under the scope `"91ab"` is a different
address and a different execution. After the execution finishes, the row
stays for 72 hours from `terminal_seen_at`, both bindings taking the
default horizon; a click that arrives in that time is a recorded drop, and
after the next reap past it the address is free again.

## Consequences

- One lookup answers "which execution is this?" for every binding of a
  document, and the unique index is what stops two first events for one
  key from opening two executions; how the race resolves is the delivery
  record's.
- Hosts keep their partitions apart through `scope` alone, and the package
  never learns what a partition is.
- Execution ids carry no information. Nothing can compute an execution id
  from a key, so every path to an execution by key goes through this table,
  and an id seen in a log reveals nothing about the address it served.
- New revisions of a document reach new executions without touching the
  address table or existing executions; the resolver is the one place the
  host decides it.
- A late event within the horizon is a visible, recorded drop instead of a
  second execution for one key. After the horizon, a new event for the
  same address opens a fresh execution; that is the intended end of the
  row's life, and a host that wants a longer tail lengthens the horizon.
- Retention needs a host that calls `reap/2`. A host that never schedules
  it keeps every row forever, which is correct and only costs space.
- `always_new` executions are invisible to this table. A later record that
  wants to reach them by key has to decide a different address for them;
  this one gives them none.
- This record leaves to later records: the get-or-create transaction and
  its race, how the scope rides with an event, the names of the recorded
  outcomes, and the code that creates the table.
