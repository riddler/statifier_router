# ADR-0002: Addressing: one table from (scope, document, key) to an execution id the router mints, scope an opaque host string, the host's chart resolver, a row that outlives its execution for the longest dedupe horizon, reaping as a plain function, and no row for always_new

Status: accepted

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

## Amendment (2026-09-19, sr-v56): the chart an existing execution is stepped on

Status: accepted

Section 4 decides which chart a new execution starts on, and says the
router asks the host's resolver only when it is about to create one. It
does not say where the router gets the chart of an execution that
already exists, and the delivery record needs one for every step of
such an execution: `StatifierPersistence.Executions.step/5` takes the
compiled machine as an argument (statifier_persistence a1a83a2).

- **By content hash, never by document.** An existing execution is
  stepped on the chart it started on, named by the content hash its
  execution record carries (`StatifierPersistence.Storage.fetch_execution/2`).
  The document is never consulted, so a new revision of a document still
  changes only where new executions start (section 4).
- **The host compiles it, through a second callback.** Beside the
  resolver, the host supplies a chart resolver,
  `(content_hash) -> {:ok, machine} | :error`. It is the shape
  statifier_persistence's driver already takes for the same need, a chart
  it does not hold, and for the same reason: a stored chart blob is opaque
  to statifier_persistence, so only the host that saved the chart can
  compile it (`StatifierPersistence.Driver`'s `chart_resolver:` option,
  statifier_persistence a1a83a2). The router calls it only when it is
  about to step an existing execution, and never decodes a stored chart
  itself.
- **A chart the host cannot resolve is an error, not an outcome.** When
  the chart resolver answers `:error`, the delivery's transaction rolls
  back and `route/3` returns `{:error, {:chart_not_resolved,
  content_hash}}`, as ADR-0004, section 7 decides for a failure that is
  not about the event and the binding.

A host with a publish store implements both callbacks over it: the
resolver reads which revision of a document is active, and the chart
resolver reads a chart by its content hash. The option that carries the
chart resolver is the code half's.

## Note (2026-09-20, sr-5pi): the hash an execution is recorded under, and the hash a resolver answers

A Note, not an amendment: it decides nothing and changes no decision.
Section 4 and the Amendment above stand as written; this records what
the code already does, so that the next reader does not have to derive
it.

- **The recorded hash comes from the machine, never from the resolver's
  answer.** `StatifierRouter.Delivery` hands the resolver's machine to
  `StatifierPersistence.Executions.create/4` and discards the
  `content_hash` beside it. statifier_persistence derives the hash it
  stores on the execution record from that machine's own
  `Statifier.Machine.identity/1` (statifier_persistence 0.12.0,
  `StatifierPersistence.Executions`, the persist tail its `create/4`
  and `step/5` share; `StatifierPersistence.Storage.save_chart/3` says
  the same of a stored chart - "never a caller-supplied hash").
- **So the two hashes have to be equal, and equality is the host's to
  keep.** The hash the Amendment hands `:chart_resolver` for an
  existing execution is the recorded one. A resolver that answers a
  hash its own machine does not derive is asking, one delivery later,
  for a chart under a hash it never issued, and the delivery ends in
  `{:error, {:chart_not_resolved, content_hash}}`.
  `StatifierRouter.Resolver`'s own documentation already states the
  rule and its example builds the hash with
  `Statifier.Machine.identity/1`; this Note is where the record says
  it.
- **Not checked in code, deliberately.** Refusing a mismatch would need
  a new term in the error vocabulary ADR-0004 owns, for a fault only a
  host that ignored the documented rule can produce, and the check
  would run on the create path of every delivery. The rule is stated
  instead, here and in `StatifierRouter.Resolver`.

## Note (2026-09-20, sr-rh9): what one reap is called with and answers, and the row whose execution is gone

A Note, not an amendment: it decides nothing and changes no decision.
Section 6 stands as written; it names `reap/2` without saying what the
function is called with or what it answers, and it does not describe one
row shape the code meets. Both are recorded here so the next reader does
not have to derive them.

- **Its third argument is optional, and so is every option in it.**
  `StatifierRouter.Addresses.reap/2` takes the configuration, the host's
  current bindings, and a keyword list of three keys: `:now`, the reap's
  time as a UTC `DateTime`, defaulting to `DateTime.utc_now/0`; `:limit`,
  a positive integer, the most rows one call examines, defaulting to
  1000; and `:after`, `nil` or a positive integer, examining only rows
  whose id is greater than it. A key outside those three, a list that is
  not a keyword list, or a malformed value is refused before anything is
  read.
- **It answers with a count of each write it made and a cursor.**
  `{:ok, %{stamped: s, deleted: d, next: n}}`: `s` is how many rows this
  call stamped `terminal_seen_at` on, `d` how many it deleted, and `n` the
  id of the last row it examined when it examined a full `:limit` of them,
  `nil` at the end of the table. A host sweeps the whole table by calling
  again with `after: n` until `n` is `nil`; a host that always calls with
  no options examines the first `:limit` rows every time and frees nothing
  behind them. Section 6 leaves the schedule to the host, and this is what
  the host has to schedule.
- **A row whose execution the store no longer holds is deleted at the reap
  that first reads it.** Section 5 counts a row's horizon from
  `terminal_seen_at`, the first time this package read the execution's
  status as terminal. An execution the store no longer holds has no status
  to read - `StatifierPersistence.Storage.fetch_execution/2` answers
  `{:error, :execution_not_found}` - so there is no horizon to start. The
  horizon exists so that a late event for the address resolves to the
  finished execution and is recorded as a drop (section 5); once the
  execution is gone no delivery can reach it and no drop can be recorded,
  so keeping the row keeps nothing, and it is deleted whatever the
  document's horizon. Every other `{:error, reason}` from that read still
  ends the call before it writes anything, as it always did. A row already
  stamped is never read again, so an execution removed after its row was
  stamped is freed by its horizon rather than by this rule.
- **It is latent, and it is not only about tidiness.**
  statifier_persistence 0.12.0 has no path that deletes an execution, so
  no host reaches this today. It is recorded because the refusal it
  replaces carried no cursor: one such row would have ended every sweep
  that reached it, and the rows behind it would never have been examined
  again.

## Note (2026-09-20, sr-99d): the first of section 8's future readers

A Note, not an amendment: it decides nothing, and this record stays at
proposed with its Decision untouched.

Section 8 names sinks, timers and execution-to-execution sends as the
address table's **future** readers and says none of them is in that
release. [ADR-0006](0006-the-execution-target.md) opens the third of
them, at proposed. What that record adds to this one, and what it
deliberately does not:

- **A second reader, no second writer.** An execution-to-execution send
  resolves `(scope, document, key)` through this table and, when its
  `create` calls for one, creates through the same get-or-create inside
  the delivery transaction, which is the first of the two writers section
  8 names; the other is `reap/2`. Nothing in it writes an address row by
  another path, so section 8's list of writers is unchanged.
- **The scope comes from this table, not from the chart.** That record
  reads the sending execution's own address row by its execution id and
  takes the `scope` from it, so a chart never names a scope and section
  2's partition holds without the author being trusted to keep it. The
  `execution_id` index the code half added is what makes that read
  cheap; the unique index of section 1 is on the triple, so the one
  address row per execution that read relies on is an invariant of the
  create path rather than a constraint the schema enforces.
- **Section 7 is load-bearing there.** An `always_new` execution has no
  row, so it has no scope and no key: that record refuses its sends for
  the same reason this one gives it no address. Section 7's closing
  sentence, that a later record wanting to reach such executions by key
  has to decide a different address for them, still stands undecided.
- **Timers are still future, and the sink is not a reader of this
  table.** This Note narrows section 8 by one reader and nothing else.
  [ADR-0005](0005-routes.md) has since decided the outbound half, and a
  sink there resolves through a per-host route registry rather than
  through an address; what section 8 anticipated for sinks is that
  record's to answer, not this Note's.

## Note (2026-09-22, sr-52v): accepted

This record and its 2026-09-19 Amendment are **accepted**. Both status
lines were flipped in place on the operator's word of 2026-09-22, after
statifier_router 0.2.0 was published; nothing above this Note changed.
Every claim either makes was re-verified at `0cea19c` on `main`, against
the dependency versions `mix.lock` pins there (statifier 2.6.0,
statifier_persistence 0.13.0, read at its `v0.13.0` tag).

Four sentences above are met by this Note rather than edited - the first
two speak of a status, the last two of what this release holds:

- The 2026-09-20 Note (sr-99d) opens "A Note, not an amendment: it decides
  nothing, and this record stays at proposed with its Decision untouched."
  Its first half still holds: that Note decided nothing, and the Decision
  is untouched by this flip too. Its "stays at proposed" is what this Note
  supersedes.
- The same Note says [ADR-0006](0006-the-execution-target.md) opens the
  third of section 8's future readers "at proposed". ADR-0006 is accepted
  on `main` as of merge `0cea19c`. The sentence is left as written.
- Section 8 reads "In this release the only resolver is delivery from a
  binding", which was true of 0.1.0; the sr-99d Note already narrows it by
  naming the execution-to-execution send as the second reader, and the
  code has one (`StatifierRouter.Addresses.by_execution/2`).
- Section 8 also says of sinks, timers and execution-to-execution sends
  that "none of them is in this release". That is no longer true of the
  execution-to-execution send:
  [ADR-0006](0006-the-execution-target.md), accepted on `main` as of merge
  `0cea19c`, decides it, and `StatifierRouter.SendHandler` implements it
  over the reserved execution target, reading the sender's address row
  through `StatifierRouter.Addresses.by_execution/2`. Sinks and timers
  remain future readers of this table: a sink resolves through the route
  registry ADR-0005 decides, and nothing under `lib/` reads an address for
  a timer. The clause is left as written, under the rule that a later
  record on `main` naming the change carries it.

The status cell for this record in `docs/adr/README.md` is flipped by a
later bead, after all seven records, so the index lags this file until
then.

## Amendment (2026-09-25, sr-1b2): a host may mint the execution id

Status: accepted

Section 3 has the router mint every execution id, as a UXID with the
prefix `ex`, and leaves the format to the code half. A host that already
names its executions - its own prefix, its own id shape, an id its other
tables carry - has had no way to make the router's id its own. This
Amendment lets the host supply the mint while the router keeps the place
it is called from.

- **The key.** `StatifierRouter.Config` takes one optional key,
  `:execution_id`: a module exporting `execution_id/3`, called as
  `module.execution_id/3`, or a fun of arity 3. `Config.new/1` checks
  that shape and nothing more, as it checks `:on_create` and `:on_step`
  (ADR-0003, the Amendment of 2026-09-25), and refuses any other value
  with `{:error, {:invalid_value, :execution_id, value}}`.
- **What it is handed.** `(scope, document, key)`: the delivery's scope,
  the document the binding or the send names, and the key. It is called
  at the two places section 3's mint was: the address row an `:if_absent`
  miss inserts, and every create an `:always_new` delivery makes
  (section 7).
- **Where its answer goes.** The answer is the execution id the address
  row carries, the id `StatifierPersistence.Executions.create/4` (or the
  host's `:on_create`) is handed, and the id every ledger row naming the
  execution carries. The dedupe table has no execution id column and
  gains none: a duplicate the dedupe claim catches never reaches the
  mint, so it calls nothing and the id already on the address row
  stands. A read address row and a `:never` miss mint nothing either.
- **What it must answer.** A non-empty string. Any other answer raises
  `ArgumentError` from the delivery, as a malformed hook answer does
  (ADR-0003, the Amendment of 2026-09-25); a raise from the callback
  itself propagates unrescued, as ADR-0003, section 1 leaves a raise. The id
  must also be new: statifier_persistence refuses a create under an id
  it already holds with `{:error, :execution_exists}` (its `create/4`
  documentation, statifier_persistence 0.18.0), which rolls the
  delivery back to its savepoint, the address row it inserted with it,
  and is returned.
- **What section 3 still says.** The router reads no meaning into an id,
  whoever minted it. Section 3's "never derived from the address" and
  "unrelated ids" describe the default mint and hold for it unchanged.
  A host's callback is handed the address and may derive from it; a
  host that derives the id from the address alone answers the same id
  the second time that address is filled - after a reap, or on every
  `:always_new` delivery - and meets the refusal above. Keeping ids new
  is the host's.
- **A mint that is not used.** Under `:if_absent` the mint runs before
  the insert that races for the address row. A delivery that loses the
  race reads the winner's row and steps the winner's execution, so the
  id its callback answered is never written anywhere. A callback that
  records the ids it hands out will hold some that name no execution.
- **Absent is today.** With the key left out, the id is a UXID with the
  prefix `ex`, exactly as before this Amendment.

**Where the code is.** `StatifierRouter.Config`, whose `hooks/2` checks
the key, and `StatifierRouter.Delivery`, whose `mint_execution_id/4`
calls the callback or mints the default and checks the answer, in the
pull request that carries this Amendment. The execution id tests pin the
host's id on the address row, the created execution and the ledger, the
duplicate that mints nothing, each refused answer, and the default.

## Note (2026-09-25, sr-cgw): a host column at a fixed position

A Note, not an amendment: it decides nothing and changes no decision.
Section 1 leaves the migrations that create the address table, and the
table prefix a host may set, to the code half. This records what the
code half now also lets a host do there, so that the next reader does
not have to derive it from the migrations.

- **Three layout options, statifier_persistence's.**
  `StatifierRouter.Migrations.up/1` takes `:leading_columns`,
  `:timestamps_position` and `:column_collations` under the spellings
  and validation rules statifier_persistence's migrations helper uses
  (its `StatifierPersistence.Ecto.Config`, statifier_persistence
  0.18.0). They are options of the migration, never keys of
  `StatifierRouter.Config`; `down/1` accepts them and ignores them.
- **All four tables, each laid out by the version that creates it.**
  V01 lays out the address, dedupe and routing ledger tables and V02 the
  subscription table. A host column goes immediately after `id` on all
  four; `inserted_at` moves to follow it on the three that have one (the
  dedupe table has none); a collation applies wherever a version declares
  the named text column. No version re-places a column in a table that
  already exists.
- **Section 1's columns are unchanged.** The address table still holds
  exactly the columns section 1 lists, with the unique index on
  `(scope, document, key)`. A host column is one the package never reads
  or writes: `StatifierRouter.Schema.Address` does not declare it.
- **Absent is today.** With none of the three set, every table is built
  exactly as before.

**Where the code is.** `StatifierRouter.Migrations`, whose `layout!/1`
validates the three options, and `StatifierRouter.Migrations.V01` and
`StatifierRouter.Migrations.V02`, whose `up/1` places the columns, in
the pull request that carries this Note. The host column tests read each
table's columns back from the database catalog under the three options,
and the migration tests read them back under none.

## Note (2026-09-25): the sr-1b2 Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The operator accepted the `## Amendment (2026-09-25,
sr-1b2)` on 2026-09-25, and its `Status:` line moved from `proposed` to
`accepted`. Its code landed in PR 90 (`0f0ebb0`) and shipped in
statifier_router 0.6.0 (tag `v0.6.0`, at `0854a99`). The record's own
status on line 3 was already `accepted` and was not touched, and the
sr-cgw Note above carries no status of its own.

Every claim was re-verified by anchor at `0854a99`, which is both the
tag and `main` at the time of the flip:

- `StatifierRouter.Config`'s private `hooks/2` checks `:execution_id`
  against `execution_id/3`, as it checks `:on_create` and `:on_step`.
- `StatifierRouter.Delivery`'s private `mint_execution_id/4` mints the
  default UXID when the key is `nil` and calls the host's callback
  otherwise.
- The tests are in `test/statifier_router/execution_id_test.exs`.

## Note (2026-09-26, sr-up8j): the address table's columns under a host column

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. The third bullet of the sr-cgw Note says
the address table "still holds exactly the columns section 1 lists".
With `:leading_columns` set that is loose: the table then holds one
more column per host column, which the bullet's next sentence goes on
to describe. Read that bullet's first sentence as:

- **Section 1's columns are unchanged.** The address table holds every
  column section 1 lists, unchanged, plus any host column, with the
  unique index on `(scope, document, key)`.

"Unchanged" is each listed column's name, type and nullability.
`timestamps_position: :leading` moves `inserted_at` to follow the host
columns, and `:column_collations` may declare a collation on a listed
text column, both as the sr-cgw Note's second bullet says; section 1
decides neither a column order nor a collation, so neither changes
what it lists. With none of the three layout options set, the table is
built exactly as before, as the sr-cgw Note's last bullet says. The
implicit `id` primary key, which section 1 does not list either way,
is not changed by this Note.

**Where the code is**, each read at `1e72588`:

- `StatifierRouter.Migrations.up/1` takes `:leading_columns` and
  validates it in the private `layout!/1`.
- `StatifierRouter.Migrations.V01.up/1` creates the address table with
  the host columns right after `id`, through the private
  `add_leading_columns/1`, then the six columns section 1 lists;
  `StatifierRouter.Migrations.V02` creates only the subscription table.
- `StatifierRouter.Schema.Address` declares section 1's columns and `id`
  and no host column, so the package never reads or writes one.
- The test "place a leading column, the timestamp and a collation on all
  four tables" in `test/statifier_router/host_columns_test.exs` reads
  the address table's column names, in order, and their collations back
  from the database catalog.

## Amendment (2026-09-26, sr-3o5z): a host column may not reuse a package column's name

Status: accepted

The sr-cgw Note above gives `StatifierRouter.Migrations.up/1` a
`:leading_columns` option and says it is validated under
statifier_persistence's rules. Those rules refuse a malformed entry and
a name given twice, and nothing else, so a host column named like a
column the package declares - `scope`, `inserted_at` - passed
validation and the version's `CREATE TABLE` then failed in Postgres
with a duplicate column error. This Amendment decides that the router
refuses such a name itself, before any DDL.

- **What is refused.** A `:leading_columns` name that a table the call
  creates already declares: any column `StatifierRouter.Migrations.V01`
  lists for the address, dedupe or routing ledger table or
  `StatifierRouter.Migrations.V02` lists for the subscription table.
  `up/1` raises `ArgumentError` naming each such column and the tables
  that declare it. The comparison is on the name exactly as given.
- **The primary key is not in the set.** Whether a table gets an
  implicit primary key, and under what name, is the host repo's
  `:migration_primary_key` configuration, which Ecto's `table/2` reads
  inside the migration runner; the package does not declare that
  column. A repo that sets `migration_primary_key: false` may lead with
  its own `id: {:bigserial, primary_key: true}`, and that migrated
  before this Amendment and still does. A leading column that repeats
  the name of the primary key the repo configures (`id` by default)
  is not refused here and fails in Postgres as it did before.
- **Only the tables the call creates.** The set is taken from the
  versions `from:` and `version:` walk. A name only a table outside that
  span declares is a host column like any other: `up(from: 2)` may lead
  with `expires_at`, which only the dedupe table has, and
  `up(version: 1)` with `invoke_id`, which only the subscription table
  has. Both migrated before this Amendment and still do.
- **`down/1` is unchanged.** It creates no table and accepts and ignores
  the layout options, as the sr-cgw Note says.
- **Nothing that worked stops working.** Every name refused here made
  the migration fail before, whatever the repo's `:migration_primary_key`:
  the refused names are the package's own columns, never the primary
  key. The refusal moves that failure ahead of the DDL and names the
  column.
- **The router decides for itself.** This departs from the sr-cgw
  Note's "under the spellings and validation rules
  statifier_persistence's migrations helper uses" in this one rule: the
  spellings are unchanged, and statifier_persistence's helper does not
  refuse a package column's name at the time of writing. Whether it
  should is that package's call; this record does not wait on it.

**Where the code is.** `StatifierRouter.Migrations`, whose `up/1`
calls the private `refuse_package_column_names!/2` over the span, which
reads the column sets from the private `@package_columns` attribute, in
the pull request that carries this Amendment. The tables those sets
mirror are the `up/1` of `StatifierRouter.Migrations.V01` and of
`StatifierRouter.Migrations.V02`, read at `98d6e3e`. In
`test/statifier_router/host_columns_test.exs`, "reject a leading column
a table the call creates already declares" pins the refusal and its
message for one name per distinct set of declaring tables; "is refused
for every column the tables the call creates declare" reads every
column but `id` of the plainly migrated tables back from the database
catalog and checks each is refused under the span that creates its
table; "is a host column when only a table outside the call declares
it" migrates the two names above; and "leads with a primary key of the
host's own under migration_primary_key: false" migrates a leading `id`
with the repo's implicit primary key turned off.

## Note (2026-09-26): the sr-3o5z Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The operator's word of 2026-09-26 is to accept the
records whose code has been published, and the `## Amendment (2026-09-26,
sr-3o5z)` above is one: its `Status:` line moved from `proposed` to
`accepted`. Its code landed in PR 101 (`a018c43`, with `d160c59`, which
left the primary key out of the refused set) and shipped in
statifier_router 0.7.0 (tag `v0.7.0`, at `672eaa5`, published on Hex
2026-09-26). The record's own status on line 3 was already `accepted` and
was not touched, and the Note of 2026-09-26 on the columns under a host
column carries no status of its own.

Every claim was re-verified by anchor at `672eaa5`, which is both the tag
and `main` at the time of the flip:

- `StatifierRouter.Migrations.up/1` calls the private
  `refuse_package_column_names!/2` over the span before any version's
  `up`, and it raises `ArgumentError` naming each colliding column and the
  tables that declare it; the comparison is `name in columns`, on the
  name as given.
- The private `@package_columns` attribute lists, for version 1, every
  column `StatifierRouter.Migrations.V01`'s `up` adds to the address,
  dedupe and routing ledger tables and, for version 2, every column
  `StatifierRouter.Migrations.V02`'s `up` adds to the subscription table,
  `inserted_at` included where the table has it and no `id` in any set.
  No commit between `98d6e3e` and `672eaa5` other than `a018c43` touches
  either version module.
- The set is taken from the span `from:` and `version:` walk (the
  private `span!/3`), so a name only a table outside the span declares
  passes.
- `down/1` parses the layout options with `up/1`'s rules and never calls
  the refusal.
- The tests are in `test/statifier_router/host_columns_test.exs`: "reject
  a leading column a table the call creates already declares", "is
  refused for every column the tables the call creates declare", "is a
  host column when only a table outside the call declares it" and "leads
  with a primary key of the host's own under migration_primary_key:
  false".
- The 0.7.0 section of `CHANGELOG.md` names the refusal as a fix.

The sentence "statifier_persistence's helper does not refuse a package
column's name at the time of writing" is about that package at the time
of writing, and this Note does not re-read it.

## Note (2026-09-26, sr-rk1o): a migrated execution's next delivery

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. It records what the code already does when
statifier_persistence migrates an addressed execution onto another chart
(`StatifierPersistence.Executions.migrate/4`, sp-ADR-0013), so that the
next reader does not have to derive it. The operator ruled on
2026-09-26 that this needs no router code. Code cites are read at
`1b4aacd`; statifier_persistence cites are read at its `v0.18.0` tag
(`453f630`), the version this package's `mix.lock` resolves.

- **The address row holds no content hash, so a migration leaves it
  alone.** Section 1's columns name the execution by its id and nothing
  else (`StatifierRouter.Schema.Address`). `migrate/4` rewrites the
  execution record's content hash, identity and position together and
  touches nothing of this package's, so the row that addressed the
  execution before the migration addresses it after, unchanged.
- **The next delivery steps on the `to` chart.** The chart an existing
  execution is stepped on is the one named by the content hash its
  execution record carries, compiled through the host's
  `:chart_resolver` (the Amendment of 2026-09-19 above;
  `StatifierRouter.Delivery`'s private `existing/5`). After a migration
  that record carries the `to` hash, so the next delivery asks
  `:chart_resolver` for the `to` chart and steps on it. The resolver has
  to answer for that hash, which it does when the host saved the `to`
  chart under it before migrating; otherwise the delivery ends in
  `{:error, {:chart_not_resolved, content_hash}}`, as the Amendment
  says. The hash `:chart_resolver` is asked for is the recorded one, as
  the Note of 2026-09-20 on the hash an execution is recorded under
  says; `migrate/4` records the `to` machine's own hash, so that Note's
  equality holds after a migration as it does after a create.
- **A delivery during a migration waits, and one that read the record
  first is retried.** `migrate/4` and `step/5` both run under the
  execution's serialization, so a delivery whose `step/5` reaches the
  lock while a migration holds it waits for the migration to finish.
  The router reads the execution record, and so picks the chart, before
  `step/5` takes that lock; a delivery that read the record before the
  migration committed hands `step/5` the `from` chart, and `step/5`'s
  load refuses it with `{:error, {:identity_mismatch, stored,
  supplied}}`. That is an error, not an outcome (ADR-0004, section 7):
  the delivery rolls back, and when the source hands the event over
  again (ADR-0003, the Note of 2026-09-21 on redelivery), that attempt
  reads the `to` hash.
- **Retiring the `from` chart stays safe.** `StatifierRouter.PinSource`'s
  `count/2` counts the address rows naming the executions the retire
  call hands it, which are the `:active` executions on the hash being
  retired; it reads no content hash. An execution migrated off the
  `from` chart is no longer among them, so its unchanged row no longer
  pins the `from` chart, and a row naming an execution still on that
  chart still does.

What a delivery to an execution a migration parked answers is
ADR-0004's, and its Note of 2026-09-26 says it. No test in this
repository exercises a migrated or a parked execution yet; this Note is
read from the code.

## Note (2026-09-26): the address table's execution_id index

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Section 1 decides one index, the unique one
on `(scope, document, key)`, and says that no index beyond it is decided
here. The code creates one more on the address table, and this Note names
it so that the next reader does not take section 1's list for the whole
schema. Code cites are read at `d426c1c`.

- **The index is the code's.** `StatifierRouter.Migrations.V01`'s `up/1`
  creates, beside the unique index, a non-unique index on
  `execution_id` named `<table>_execution_id_index`, where `<table>` is
  the address table's name under the host's table prefix. Its moduledoc
  gives the reason: the rows naming one execution are found without a
  scan.
- **This record does not decide it.** Section 1's closing sentence
  stands: the index sits with the migrations and the table prefix, which
  section 1 leaves to the code half. The Note of 2026-09-20 on the first
  of section 8's future readers already calls it the index "the code
  half added"; this Note adds only its name and where it is created.
- **A test pins it.** "names every index on every version's tables and
  its columns", in `test/statifier_router/migrations_test.exs`, reads the
  address table's indexes back from the database and expects this one
  on `execution_id` beside the primary key and the unique index.

## Amendment (2026-09-26, sr-w58a): a primary key of the host's type

Status: accepted

Section 1 leaves the migrations that create the address table to the
code half, and the sr-cgw Note gives a host three options that place
its columns after `id` on all four tables. `id` itself stayed the host
repo's `:migration_primary_key`, and the schemas read it as an integer,
so a host whose tables follow another id convention - a sortable
string id, say - could not fit the router's tables to it. The operator
ruled on 2026-09-26 to build a primary key option. This Amendment
decides its shape.

- **One option, on the migration.** `StatifierRouter.Migrations.up/1`
  takes `:primary_key`, a keyword list with a `:type`, required, and a
  `:default`, optional, each what `Ecto.Migration.add/3` takes. It
  builds the `id` of every table a version creates - V01's address,
  dedupe and routing ledger tables and V02's subscription table - with
  that type and default, in place of the repo's
  `:migration_primary_key`, for these tables alone. The column is
  always named `id`. Any other key, a key given twice, a missing
  `:type` and a value that is neither `nil`, which is the same as
  leaving the option out, nor a non-empty keyword list raise
  `ArgumentError` before any DDL. `down/1` accepts it and ignores it,
  as it does the layout options. It is an option of the migration,
  never a key of `StatifierRouter.Config`.
- **Absent is today, byte for byte.** Left out, every version calls
  `table/2` with exactly the options it passed before, and sends
  exactly the DDL it sent before: V01, V02 and V03 as published.
- **A fresh create only.** Like the layout options, it types the key of
  the tables a version creates and re-types none that already exists.
- **The database fills the id in.** The package inserts no id of its
  own, so the key needs a default the database supplies.
- **A leading `id` is refused under the option.** With `:primary_key`
  set the package declares `id` itself, and a `:leading_columns` entry
  named `id` raises like any other package column. This narrows the
  sr-3o5z Amendment's "the primary key is not in the set" to a call
  that leaves `:primary_key` out; such a call is unchanged.
- **The schemas take the id through one type.** The four schemas in
  `StatifierRouter.Schema` declare `id` as `StatifierRouter.Schema.Id`,
  a new public module the option forces: a schema's key type is fixed
  when it compiles, and one type has to read an integer from an
  integer column and a string from a text one. Its base type is `:id`,
  so Ecto still leaves the column to the database on insert and reads
  it back. It loads and dumps an integer or a string unchanged, and
  casts exactly as Ecto's own `:id` type does: an integer, and a
  string that spells one, to the integer, and any other string
  refused. A cast that worked or failed under the default key works or
  fails the same way. A text id is never cast, so a host on a text key
  looks a row up with a where clause that binds the id uncast, not
  with `Repo.get/2` or a changeset cast.
- **The package never casts an id it binds.** The address sweep's
  cursor, the ids it stamps and deletes, and the row a delivery stamps
  terminal are bound as the table or the host handed them over, so a
  text id made of digits alone stays a string.
- **The sweep follows the id column's order.**
  `StatifierRouter.Addresses.reap/2` pages through the address table in
  the id column's order, as section 6 and the Note of 2026-09-20 on
  what one reap is called with describe it; under a text key that is
  the column's collation order. `next` is an id as the table holds it,
  an integer or a string, and `after:` takes either back: `nil`, a
  positive integer or a non-empty string. A cursor the id column cannot
  hold is refused as `{:invalid_value, :after, value}`, as a string
  cursor was before. With no cursor the read starts at the table's
  first row, where it started at the first id above zero, which is the
  same row under a `bigserial` key.

**Where the code is.** In the pull request that carries this
Amendment: `StatifierRouter.Migrations`, whose private `layout!/1`
reads the option through the private `pop_primary_key/1` and
`validate_primary_key!/1`, and whose private
`refuse_package_column_names!/3` adds `id` to every set under it; the
private `table_opts/1` of `StatifierRouter.Migrations.V01` and of
`StatifierRouter.Migrations.V02`, which hand `table/2` the key;
`StatifierRouter.Schema.Id`; the `@primary_key` of
`StatifierRouter.Schema.Address`, `StatifierRouter.Schema.Dedupe`,
`StatifierRouter.Schema.Ledger` and `StatifierRouter.Schema.Subscription`;
the private `examine/3`, `stamp/3`, `delete/2` and `after_id/1` of
`StatifierRouter.Addresses`; and the private `stamp_terminal_seen/3` of
`StatifierRouter.Delivery`. The code this replaces - `examine/3`'s
`a.id > ^after_id`, `after_id/1`'s `nil` as `0`, and the four schemas'
default key - is read at `d426c1c`. In
`test/statifier_router/primary_key_test.exs`, "every version sends
exactly the DDL it sent before the option existed" compares the DDL a
migration with no option logs against the DDL logged at `d426c1c`;
"changes only the id column of every table a version creates" pins the
option's DDL; "takes a delivery and a sweep, and a row through every
schema" and "never casts a text id made of digits alone" route parcel
scans and sweep the address table under a text key; and "refuses a
cursor the id column cannot hold" pins the refusal, as the "refuses
malformed options" test in `test/statifier_router/create_modes_test.exs`
does under the default key; in the same file, "casts a string id as
Ecto's :id does, as before the primary key option" pins the cast under
the default key.

## Note (2026-09-27): the sr-w58a Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. The operator's word of 2026-09-27 is to
accept the records whose code has been published, and the `## Amendment
(2026-09-26, sr-w58a)` above is one: its `Status:` line moved from
`proposed` to `accepted`. Its code landed in PR 113 (`b4354b6`, with
`95d8be9`, which made the id's cast exactly Ecto's `:id`) and shipped in
statifier_router 0.8.0 (tag `v0.8.0`, at `bcde361`, published on Hex
2026-09-27). The record's own status on line 3 was already `accepted`
and was not touched, and the other records of 2026-09-26 above carry
their own status or none.

Every claim was re-verified by anchor at `bcde361`. `main` at the time of
the flip is `8f95439`, whose one commit after the tag touches no file
under `lib/` or `test/`:

- `StatifierRouter.Migrations.up/1` reads `:primary_key` through the
  private `layout!/1`, `pop_primary_key/1` and `validate_primary_key!/1`:
  `nil` is the option left out, and anything but a non-empty keyword
  list, a key other than `:type` and `:default`, a key given twice and a
  missing `:type` raise `ArgumentError` before any version's `up` runs.
  `down/1` parses the same options, and no version's `down` reads the
  key; `StatifierRouter.Config` has no `:primary_key` key.
- The private `table_opts/1` of `StatifierRouter.Migrations.V01` and of
  `StatifierRouter.Migrations.V02` answers `[prefix: prefix]`, the
  options each `create table` passed at `d426c1c`, when the option is
  left out, and adds `primary_key: [name: :id] ++ primary_key` when it
  is set. `StatifierRouter.Migrations.V03` is unchanged since `d426c1c`.
- The private `refuse_package_column_names!/3` adds `:id` to every
  table's set when the option is set, and leaves the sets as they were
  when it is not.
- `StatifierRouter.Schema.Id` has the base type `:id`, loads and dumps
  an integer or a binary unchanged, and casts through
  `Ecto.Type.cast(:id, id)`. The `@primary_key` of
  `StatifierRouter.Schema.Address`, `StatifierRouter.Schema.Dedupe`,
  `StatifierRouter.Schema.Ledger` and `StatifierRouter.Schema.Subscription`
  is `{:id, StatifierRouter.Schema.Id, autogenerate: true}`; at `d426c1c`
  each took Ecto's default key.
- In `StatifierRouter.Addresses`, the private `examine/3` orders by
  `a.id`, starts with no `where` when no cursor is given, binds a cursor
  in `fragment("? > ?", a.id, ^after_id)`, and answers a cursor that
  fails to encode as `{:invalid_value, :after, after_id}`; the private
  `stamp/3` and `delete/2` bind the ids in `fragment("? = ANY(?)", a.id,
  ^ids)`; the private `after_id/1` takes `nil`, a positive integer or a
  non-empty binary. At `d426c1c` `examine/3` read `a.id > ^after_id` and
  `after_id/1` answered `nil` as `0` and refused every string.
- The private `stamp_terminal_seen/3` of `StatifierRouter.Delivery`
  binds the row's id in `fragment("? = ?", a.id, ^id)`.
- The tests the Amendment names are present under those names in
  `test/statifier_router/primary_key_test.exs` and
  `test/statifier_router/create_modes_test.exs`.
- The 0.8.0 section of `CHANGELOG.md` names the option,
  `StatifierRouter.Schema.Id` and the text-keyed sweep, and says that
  the option left out changes nothing.

## Amendment (2026-09-30, sr-xgi8): a durable execution's BasicHTTP location is a rotatable token the router mints, and the front that answers at it

Status: accepted

statifier 2.10.0 ships the W3C Basic HTTP Event I/O Processor,
`Statifier.Send.BasicHTTP`, with a pure inbound decoder, and its record
places the front that delivers to a persisted execution in this package
(st-ADR-0075, `docs/adr/0075-basichttp-event-io-processor.md` in
statifier-ex, decision 1, read at its `v2.10.0` tag). That record leaves
two things to this package's own record: "Whether a durable execution's
location carries more than its id, and whether a front authenticates the
POST" (its decision 3). Both were ruled by the operator, 2026-09-30:

> the location of a durable execution carries an unguessable, rotatable
> per-execution token minted by the router, never the bare execution id;
> the front authenticates nothing beyond possession of the location, and
> the docs say plainly that a location is a bearer capability.

Resolving a location to an execution is an address-table read, so the
decision is this record's. This Amendment decides what the ruling leaves
open: how the token is minted, stored, rotated and resolved, how an
execution's `_ioprocessors` entry comes to carry it, and what the front
is. Code cites in this package are read at `bb292c8`; statifier cites at
its `v2.10.0` tag; statifier_persistence cites at 0.18.0, the version
this package's `mix.lock` resolves.

**What bounds it.**

- **The stock processor writes the session id into the location.**
  `Statifier.Send.BasicHTTP.ioprocessors_entry/2` answers `%{"location"
  => base_url <> "/" <> session_id}` from the registration's `:base_url`
  and the entry context's `session_id`.
- **The entry is written once, when the execution starts.**
  `Statifier.Evaluator.SystemVariables`' moduledoc: the entries "are
  written here, once, when the session starts, and nowhere else"; a
  persisted position carries them, and `MachineState.put_send_types/2`,
  the re-stamp on every later drive, "does not rewrite `_ioprocessors`".
  ADR-0005, section 6 already says the create-side snapshot must travel
  inside `initialize:` for the same reason.
- **An execution this package creates has no session id of its own
  choosing.** `StatifierRouter.Delivery`'s private `create_options/1`
  hands `create/4` the configuration's `:persistence_options` under
  `initialize:` and nothing else;
  `StatifierPersistence.Executions.create/4` passes `initialize:` to
  `Statifier.Interpreter.initialize/2`, which passes it straight to
  `Statifier.MachineState.new/2`, whose `:session_id` defaults to a
  freshly generated `sess_` id. The stock location therefore names an id
  the address table does not hold, so the stock registration cannot
  serve a durable execution whatever the ruling said.
- **The decoder and its status rule.** `Statifier.Send.BasicHTTP.decode/1`
  takes `:method`, `:content_type`, `:body`, `:query` and an optional
  `:send_key` and answers `{:ok, %Statifier.Event{}}` or `{:error,
  reason}`. st-ADR-0075, decision 5 gives the statuses: 204 once the
  event is enqueued, 405 with `Allow: POST` for
  `{:method_not_allowed, method}`, 400 for any other decode error, and
  404, the front's own, for a location that reaches nothing. Its
  Amendment of 2026-09-30 puts the send's key in the `scxml-send-key`
  header, makes delivery at-least-once, and says this package's durable
  front "is the one that will" deduplicate on it.
- **A delivery of a prebuilt event already has a door.**
  `StatifierRouter.Delivery.deliver_event/4` takes a plan, a key and an
  envelope carrying the event, and settles it in the one transaction
  ADR-0003, section 1 describes: the dedupe claim, the address lookup,
  `step/5`, the ledger row (ADR-0006, section 2).
- **Every address read selects every declared column.**
  `StatifierRouter.Schema.Address` declares section 1's columns, and an
  Ecto query over it selects each of them.

### 1. The token: minted by the router, stored in a table of its own, one per address row

- **What it is.** 32 bytes from `:crypto.strong_rand_bytes/1`, written as
  unpadded URL-safe base64: 43 characters from `A-Z a-z 0-9 - _`, 256
  bits, a single path segment with nothing to escape. It is derived from
  nothing: not the address, not the execution id, not the scope. Two
  tokens, for one execution or two, are unrelated, as two execution ids
  are under section 3.
- **Where it is stored.** A new table, `locations` under the host's table
  prefix, created by a new migration version, `StatifierRouter.Migrations.V04`.
  Its columns are the implicit `id` (typed by the `:primary_key` option
  as V01's tables are), `address_id`, a reference to the address row's
  `id` with `ON DELETE CASCADE`, `token` and `inserted_at`. `address_id`
  and `token` each carry a unique index. The layout options of the sr-cgw
  Note and the `:primary_key` option of the sr-w58a Amendment apply to it
  on V01's terms; the reference column takes the address table's key
  type, so a host that built V01 with `:primary_key` passes the same
  option to V04.
- **Why a table and not a column on the address row.** A column would be
  declared on `StatifierRouter.Schema.Address`, so every address read -
  every delivery - would select it, and a host that took this release
  without running V04 would fail on every delivery. A table of its own is
  read and written only when the configuration sets the key of decision
  4, so a host that does not use BasicHTTP needs no migration.
- **It is stored as minted.** The location is already in the execution's
  own datamodel (`_ioprocessors`, decision 4), which statifier_persistence
  keeps in the same database, so a hashed column would hide nothing from a
  reader of that database and would leave `location/2` (decision 2)
  nothing to answer.
- **When it is minted.** Inside the delivery's transaction, when an
  `:if_absent` insert of an address row is the insert that wrote the row
  (the private `insert_or_existing/4` of `StatifierRouter.Delivery`), and
  only when the configuration sets decision 4's key: the location row is
  inserted beside it, before `create/4`. A delivery that loses the race
  for the address mints a token that is never written, as its execution
  id is never written (the sr-1b2 Amendment's "A mint that is not used").
  A delivery that rolls back to its savepoint takes the location row with
  the address row. This covers every path that creates under an address:
  a binding's delivery and an execution-to-execution send (ADR-0006,
  section 2) alike.
- **An `always_new` execution has no location.** It has no address row
  (section 7), so it has nothing a location row can reference, and the
  front delivers only through an address (decision 3). Its `_ioprocessors`
  entry carries no `"location"` key (decision 4). Section 7's closing
  sentence stands undecided.
- **A row with no location.** An address row written before this release,
  or while the key was unset, has no location row, and its execution's
  `_ioprocessors` has no BasicHTTP entry at all, since the entries were
  written at its start. Decision 2's rotation gives such a row a location
  the front resolves; the execution's own `_ioprocessors` stays as it
  started.

### 2. Rotation: a plain function the host calls, after which the old token reaches nothing

- **The function.** `StatifierRouter.BasicHTTP.rotate_location/2` takes the
  configuration and an execution id, reads that execution's address row
  (`StatifierRouter.Addresses.by_execution/2`), mints a new token as
  decision 1 does, and writes it in one statement that inserts the row's
  location or replaces its token. It answers `{:ok, location}`, the new
  location string, or `{:error, {:no_address, execution_id}}` when no
  address row names the execution, which is what an `always_new`
  execution answers. `StatifierRouter.BasicHTTP.location/2` reads the
  current location the same way and answers `{:ok, location}` or
  `{:error, :no_location}`.
- **What an old token answers.** Once the rotation commits, the old token
  resolves nothing, and a POST to it is answered as an unknown location:
  404 (decision 5).
- **What rotation does not reach.** The execution's own `_ioprocessors`
  entry was written when it started and is never rewritten (the
  SystemVariables moduledoc, quoted above: "and nowhere else"). After
  a rotation the chart still reads the location it started with, which
  now answers 404. A host that
  rotates hands the location `rotate_location/2` answers to whoever
  should hold it; a chart that sends its own location to a peer after a
  rotation sends a dead one. Changing that needs a statifier change and
  is not assumed here.
- **The same stands for a moved base URL.** `location/2` and
  `rotate_location/2` build the location from the configuration's current
  base URL; the chart keeps the one it started with, as st-ADR-0075's
  decision 9 table notes for a live session.
- **No process.** Nothing rotates on a schedule; the host calls it, as it
  schedules `reap/2` (section 6).

### 3. Resolution: the token names an address row, and delivery is the door that already exists

- **The read.** The front reads the location row whose `token` equals the
  request's token, with the address row it references. The address row
  gives the `(scope, document, key)` and the `execution_id`. A token with
  no row, or a string that is not 43 characters of the token's alphabet,
  is an unknown location. So is an address row whose `terminal_seen_at` is
  set: the execution is terminal, the front delivers nothing and writes
  nothing, and a retry of a POST that found it terminal is answered as the
  first answer was (decision 5).
- **The delivery.** The event is delivered through
  `StatifierRouter.Delivery.deliver_event/4` with the plan `%{id:
  "basichttp", document: row.document, create: :never, dedupe: %{by:
  :message_id, horizon_ms: 259_200_000}}`, the row's `key`, and an
  envelope whose `scope` is the row's. That is the same transaction, the
  same address lookup, the same dedupe claim and the same ledger row every
  delivery uses; the front has no write path of its own to the address,
  dedupe or ledger tables. `create: :never` because a location reaches an
  execution that exists and never makes one. The horizon is ADR-0001,
  section 1's default, the one ADR-0006, section 2 takes for the same
  reason: no binding supplies one.
- **The name `basichttp` on the ledger and the dedupe claim.** It is the
  plan's `id`, so the ledger row's `binding_id` and the dedupe row's
  claimant are `basichttp`, which tells a front row from a binding's and
  from an execution-to-execution send's (`execution`, ADR-0006, section
  2). It is reserved on ADR-0006, section 2's terms, but only on a
  configuration that sets decision 4's key: there, a binding whose `id`
  is `basichttp`, given or resolved, is refused as
  `{:reserved_binding_id, "basichttp"}`. `StatifierRouter.Config.new/1`
  refuses every key it does not know as `{:unknown_key, name}`, so a
  configuration carrying the new key was refused before this release, and
  no configuration it accepted before is refused after it.
- **Never a route.** The front is reached by an inbound HTTP request, not
  by a `<send>`: it consults no route registry, and ADR-0005, decision 1
  is unchanged - a route's `target` is a route name, and a URL there stays
  refused. BasicHTTP's outbound half is the send type of decision 4, not a
  route. ADR-0006, section 1's reserved name `execution` is neither used
  nor changed.
- **The scope a route sees.** The step runs with the row's scope set as
  a binding's delivery sets it, so a route override a step's route reads
  is the addressed execution's scope's.

### 4. The location string: a processor this package owns, registered by the configuration

- **The processor.** `StatifierRouter.BasicHTTP` implements
  `Statifier.Send.Processor`. Its `ioprocessors_entry/2`, the optional
  callback statifier 2.10.0 asks when a module exports it, answers
  `%{"location" => base_url <> "/" <> token}` from the registration's
  `:base_url` and `:location_token` options, and `%{}`, an entry with no
  `"location"`, when no token is in the options. Its `deliver/3`,
  `cancel/2` and `perform/2` hand each call to `Statifier.Send.BasicHTTP`
  unchanged, so the outbound half is statifier's processor as that record
  decides it.
- **The configuration key.** `StatifierRouter.Config` takes one optional
  key, `:basichttp`, a keyword list with `:base_url`, a non-empty string,
  required, and `:transport`, a module, optional, both handed to the
  registration as statifier's processor reads them. When it is set, the
  snapshot the configuration builds (ADR-0005, section 6 and its sr-mqzz
  Amendment of 2026-09-26) registers `StatifierRouter.BasicHTTP` under the
  processor's URI, `http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor`,
  and its short form `basichttp` (st-ADR-0075, decision 2), with those
  options. A `:send_handlers` entry under either string is refused as
  `{:declared_send_types, type}`, and the key beside a `:send_types` of
  the host's own in `:persistence_options` is refused as `{:exclusive_keys,
  :basichttp, :send_types}`: the token can be added only to a snapshot
  this package builds.
- **How the token reaches the entry.** On the create of decision 1, the
  snapshot handed to `create/4` inside `initialize:` is built with
  `Statifier.Send.Types.from_send_types/1` from the same registrations,
  with `location_token:` added to `StatifierRouter.BasicHTTP`'s options.
  Every step carries the configuration's own snapshot, without the token.
  Both register the same type strings to the same modules; the one option
  they differ in is read only by `ioprocessors_entry/2`, which statifier
  calls only when the execution starts. Only statifier 2.10.0's public
  surface is used: `from_send_types/1` with a `{module, opts}` value and
  the optional `ioprocessors_entry/2` callback.
- **A host that registers statifier's processor itself** in a `:send_types`
  of its own gets statifier's location, the base URL and the session id.
  The front never resolves a session id or an execution id, so a POST
  there is answered 404.
- **What is not decided here.** What an outbound BasicHTTP send from a
  durable execution does at the executor seam, and whether its delayed
  POST survives a resume, is statifier's processor and the executor's,
  and is left to a later record.

### 5. The front: a plain function beside the webhook helper

`StatifierRouter.BasicHTTP.Front` is Plug-shaped and not a Plug, as
`StatifierRouter.Webhook` is: no dependency on Plug or Phoenix, and no
process. `handle/3` takes the configuration, a request map and the
options `deliver_event/4`'s caller passes (`:now`), and answers `{:ok,
outcome}` or `{:error, reason}`; `response/1` maps that answer to a status
and the headers to send with it.

- **The request.** `:token`, the path segment after the base URL, which
  the host cuts from the request path; and `:method`, `:content_type`,
  `:body`, `:query` and `:send_key`, the value of the `scxml-send-key`
  header or `nil`, handed to `decode/1` as they are. A request missing a
  key or carrying one of the wrong type is `{:error, {:invalid_request,
  keys}}`, naming the keys and never the token.
- **The order.** The request is checked, then the token is resolved
  (decision 3), then the request is decoded, then the event is delivered.
  A request that fails before the delivery writes nothing, and no ledger
  row records it: before the token resolves there is no scope, and the
  ledger's `scope` is `NOT NULL` (ADR-0006, section 6 meets the same
  gap). While a route is running in the calling process the front refuses
  with `{:error, {:reentrant_route, execution_id}}` before it resolves
  anything, as `StatifierRouter.Delivery.deliver/4` does.
- **Deduplication.** With a send key, the dedupe claim's message id is
  the execution id, `/`, and the key. The key is exactly eight
  `/`-separated fields (the decoder refuses any other), so the split is
  unambiguous whatever the execution id holds, and a key is deduplicated
  per execution: the same key POSTed to two executions is two messages. A
  request already enqueued within the horizon is a duplicate, answered 204
  with nothing enqueued, which is what st-ADR-0075's Amendment asks of
  this front. Without a send key, the message id is minted fresh for the
  request, so every such POST is delivered. The key is the sender's
  claim, trusted as far as the location is: a holder of the location who
  sends a key another sender will use suppresses that sender's event to
  the same execution, and nothing else.
- **The statuses.**

| `handle/3` answers | status | headers |
|---|---|---|
| `{:ok, {:delivered, "basichttp", execution_id}}` | 204 | none |
| `{:ok, {:duplicate, "basichttp"}}` | 204 | none |
| `{:ok, {:dropped, "basichttp", :finished}}` | 404 | none |
| `{:ok, {:dropped, "basichttp", :no_execution}}` | 404 | none |
| `{:error, :unknown_location}` | 404 | none |
| `{:error, {:method_not_allowed, method}}` | 405 | `allow: POST` |
| any other decode error | 400 | none |
| any other `{:error, reason}` | 500 | none |

  `deliver_event/4` does not take `dropped: unmatched_event`
  (`StatifierRouter.Delivery`'s moduledoc), so an event the execution
  selects no transition for is delivered and answered 204, which is
  C.2.1's "after it adds the received
  message to the appropriate event queue". `dropped: finished` commits its
  dedupe row and stamps `terminal_seen_at`, so a retry of that POST is
  resolved as an unknown location by decision 3's terminal rule and
  answered 404 again, not 204 as a duplicate. `dropped: no_execution` is
  an address row reaped between the read and the delivery; its location
  row went with it by the cascade. `created_and_delivered` cannot occur
  under `create: :never`. A 500 is a delivery that did not settle, and a
  sender may retry it.
- **The token is not repeated.** No ledger row, dedupe row or error the
  front returns carries the token.

### 6. A location is a bearer capability

The docs of `StatifierRouter.BasicHTTP`, `StatifierRouter.BasicHTTP.Front`
and the README say, in these words or plainer: a location is a bearer
capability. Anyone who holds it can post events to that execution, and
the router authenticates nothing beyond possession of the location, as
ruled by the operator, 2026-09-30. Hand a location only to the parties
that should reach the execution, keep it out of logs and URLs shown to
others, serve the base URL over TLS, and rotate it with
`rotate_location/2` when it may have leaked.

### What sections 1 to 8 still say

- The address table's columns, its unique index, and its two writers
  (section 8) are unchanged. The location table is written by the
  delivery's create (decision 1) and by `rotate_location/2`, and its rows
  are deleted by the cascade when `reap/2` deletes the address row they
  reference; `reap/2`'s code and its answer are unchanged, and its
  `deleted` counts address rows only. It is read by the front and by
  `location/2`.
- Section 3's execution id and the sr-1b2 Amendment's host mint are
  unchanged: the token is minted beside the id and never replaces it.
- **Absent is today.** With `:basichttp` left out, no location row is
  written, the snapshot is built exactly as before, no binding id is
  refused that was accepted before, and nothing reads or writes the
  location table, so a host that never sets the key does not need V04.

**Where the code is.** In the pull request that implements this
Amendment, which cites it: `StatifierRouter.BasicHTTP`,
`StatifierRouter.BasicHTTP.Front`, the location schema and
`StatifierRouter.Migrations.V04` as new modules;
`StatifierRouter.Config` for the key, its refusals and the conditional
reservation; `StatifierRouter.Delivery` for the mint on the winning
insert and the create's snapshot; `StatifierRouter.Migrations` for the
new version; and `mix.exs`, which requires statifier at the published
version that ships the decoder, never a git or path pin.

## Amendment (2026-09-30, sr-xgi8): the location table is opt-in, outside the version walk

Status: accepted (2026-09-30)

The Amendment of 2026-09-30 above on the BasicHTTP location stores each
token in a table "created by a new migration version,
`StatifierRouter.Migrations.V04`" (its decision 1, "Where it is
stored"), says "a host that does not use BasicHTTP needs no migration"
(decision 1, "Why a table and not a column on the address row") and "a
host that never sets the key does not need V04" ("Absent is today"),
and places the code in "`StatifierRouter.Migrations` for the new
version" ("Where the code is"). It does not say how a host runs that
version. Made the fourth member of the walk `from:` and `version:` span
(the sr-3o5z Amendment's "Only the tables the call creates"), it would
change what `StatifierRouter.Migrations.up/1` and `down/1` answer for
every host that never sets the key: an uncapped `down/1` on a database
migrated before it would drop a table that was never created, an
uncapped `up(from: 2)` or `up(from: 3)` would build a table with a
reference to the address table that a later capped rollback leaves in
place, and an uncapped `up/1` would refuse leading-column names it
accepted before. This Amendment decides that it does not, and amends
those four sentences in part: V04 is still the migration that creates
the table, and it is not a version of the walk.

- **Outside the walk.** `StatifierRouter.Migrations.up/1` and `down/1`,
  capped or not, never create, drop or require the location table, and
  refuse no leading-column name they accepted before; the versions they
  walk are V01 to V03, as on `main` at `8600d6f`
  (`StatifierRouter.Migrations`' private `@migrations`), and a version
  of 4 stays an unknown version. A host that never sets `:basichttp`
  sees no migration answer differently.
- **Two calls a host makes.** A host that sets `:basichttp` creates and
  drops the table with `StatifierRouter.Migrations.up_locations/1` and
  `StatifierRouter.Migrations.down_locations/1`, in a migration of its
  own written after the ones it already has.
- **Their options.** The storage options (`:table_prefix`, `:prefix`),
  the three layout options and `:primary_key`, each read as `up/1` reads
  it. The host passes the values its earlier migrations passed: the
  table's `address_id` references the address table's `id` and takes the
  key type `:primary_key` names.
- **Their refusals.** `:from`, `:version` and any other key raise
  `ArgumentError` before any DDL, as does a `:leading_columns` entry
  named like one of the location table's own columns (`address_id`,
  `token`, `inserted_at`, and `id` under `:primary_key`).
- **Tolerant in both directions.** `up_locations/1` creates the table
  and its two indexes only where they do not exist, and
  `down_locations/1` drops the table only if it is there, as V03 renames
  only the index it finds.
- **The rollback order.** The table references the address table, so it
  goes before V01's tables. The host's opt-in migration is newer than the
  one that created them, and Ecto's rollback undoes the newest migration
  first, so that order is the one a rollback takes. V01's `down` is
  unchanged.

**Where the code is.** In the pull request that implements the
Amendment of 2026-09-30 above and this one, which cites both:
`StatifierRouter.Migrations`, whose `up_locations/1` and
`down_locations/1` run `StatifierRouter.Migrations.V04` outside
`@migrations`, and whose "The location table, V04, is opt-in" section
says how a host writes its migration; and `StatifierRouter.Migrations.V04`,
whose `down/1` drops the table only if it exists. The existing migration
tests are unchanged from `main` and pass against that code, and a test
module of its own covers a pre-V04 rollback, the opt-in migration's full
rollback and a host that opts in from one migration.

## Note (2026-09-30): the two sr-xgi8 Amendments accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Records merge at proposed and are accepted
once their code has shipped in a published version and every claim they
make verifies against `main`, under the standing grant the operator
adopted on 2026-09-29. The `## Amendment (2026-09-30, sr-xgi8)` on the
BasicHTTP location and the `## Amendment (2026-09-30, sr-xgi8)` on the
opt-in location table are both such records: the first one's `Status:`
line moved from `proposed` to `accepted`, and the second one's from
`proposed (2026-09-30)` to `accepted (2026-09-30)`, the date left as
written. Their code landed in `1a5d8ef` and `fd21ebc` and shipped in
statifier_router 0.9.0 (tag `v0.9.0`, at `e38142f`, published on Hex
2026-09-30T16:58:50Z). The record's own status on line 3 was already
`accepted` and was not touched.

Every claim was re-verified by anchor at `e38142f`, which is both the tag
and `main` at the time of the flip; statifier cites at its `v2.10.0`
tag, the version `mix.lock` resolves, and statifier_persistence cites at
0.18.0.

**The Amendment on the BasicHTTP location.**

- What bounds it: `Statifier.Send.BasicHTTP.ioprocessors_entry/2`
  answers `base_url <> "/" <> session_id`; the
  `Statifier.Evaluator.SystemVariables` moduledoc says the entries are
  written "once, when the session starts, and nowhere else" and that
  `MachineState.put_send_types/2` "does not rewrite `_ioprocessors`";
  `StatifierPersistence.Executions.create/4` passes `initialize:` to
  `Statifier.Interpreter.initialize/2`, and `Statifier.MachineState.new/2`
  defaults `:session_id` to a generated id; `decode/1` takes the five
  request keys and st-ADR-0075's decision 5 and its Amendment of
  2026-09-30 say what the Amendment quotes.
- Decision 1: `StatifierRouter.BasicHTTP.mint_token/0` is
  `:crypto.strong_rand_bytes(32)` as unpadded URL-safe base64, derived
  from nothing. `StatifierRouter.Migrations.V04` creates `locations` with
  the `id` typed by `:primary_key`, `address_id` referencing the address
  row's `id` with `on_delete: :delete_all`, `token` and `inserted_at`,
  and a unique index on each of `address_id` and `token`;
  `StatifierRouter.Schema.Location` is its schema and
  `StatifierRouter.Schema.Address` declares no new column. The private
  `locate/3` of `StatifierRouter.Delivery` is a no-op without
  `:basichttp` and otherwise inserts the location row inside the
  delivery's savepoint, called from `insert_or_existing/4` only on the
  insert that wrote the address row, before `create/4`; the race's loser
  takes the `existing/5` branch and writes no token. An `always_new`
  create carries no token, so `ioprocessors_entry/2` answers `%{}`.
- Decision 2: `rotate_location/2` reads the row through
  `StatifierRouter.Addresses.by_execution/2`, upserts the token with
  `on_conflict: [set: [token: token]]` on `address_id`, and answers
  `{:ok, location}` or `{:error, {:no_address, execution_id}}`;
  `location/2` answers `{:ok, location}` or `{:error, :no_location}`;
  both build from the configuration's current base URL; nothing
  schedules either.
- Decision 3: `StatifierRouter.BasicHTTP.Front`'s private `resolve/2`
  refuses a string that is not the token's shape
  (`StatifierRouter.BasicHTTP.token?/1`, 43 characters of the
  alphabet), a token with no row and a row with `terminal_seen_at` set,
  each as `{:error, :unknown_location}`; `deliver/5` calls
  `StatifierRouter.Delivery.deliver_event/4` with the plan `id:
  "basichttp"`, the row's document, `create: :never` and `horizon_ms:
  259_200_000`, the row's key and scope, and sets the delivery scope
  through `StatifierRouter.SendHandler.put_delivery_scope/1`. The private
  `refuse_reserved_id/2` of `StatifierRouter.Config` adds `basichttp` to
  the reserved ids only when `:basichttp` is a list, and `new/1` refuses
  an unknown key through `reject_unknown/2`.
- Decision 4: `StatifierRouter.BasicHTTP` declares
  `@behaviour Statifier.Send.Processor`, answers the entry from
  `:base_url` and `:location_token`, and hands `deliver/3`, `cancel/2`
  and `perform/2` to `Statifier.Send.BasicHTTP`. `StatifierRouter.Config`
  validates `:basichttp` (`:base_url` a non-empty string, `:transport` a
  module), registers the module under both type strings, refuses a
  `:send_handlers` entry under either as `{:declared_send_types, type}`
  and the key beside a host `:send_types` as `{:exclusive_keys,
  :basichttp, :send_types}`; `create_persistence_options/2` rebuilds the
  snapshot with `location_token:` for a create, and the private
  `step_options/1` of `StatifierRouter.Delivery` carries the
  configuration's own snapshot. statifier 2.10.0 asks
  `ioprocessors_entry/2`, an optional callback, only at session start.
- Decision 5: `handle/3` checks the request, refuses a re-entrant call
  as `{:error, {:reentrant_route, execution_id}}`, resolves, decodes,
  then delivers; a request failing its keys is `{:error,
  {:invalid_request, keys}}`; the message id is the execution id, `/`
  and the send key, or a fresh one without a key; `response/1` answers
  the table's statuses. `deliver_event/4` never answers `dropped:
  unmatched_event` (the private `taken/7` of `StatifierRouter.Delivery`
  matches that outcome on a binding only), and the private `finished/6`
  stamps `terminal_seen_at`. No row or error the front writes carries
  the token.
- Decision 6: the moduledocs of `StatifierRouter.BasicHTTP` and
  `StatifierRouter.BasicHTTP.Front` and the README's "A BasicHTTP front"
  say a location is a bearer capability, and name TLS, logs and
  `rotate_location/2`.
- What sections 1 to 8 still say: `lib/statifier_router/addresses.ex`,
  `lib/statifier_router/schema/address.ex` and the V01 to V03 modules are
  unchanged between `bb292c8` and `e38142f`, so the address table's
  columns, its writers and `reap/2` are as they were.
- The tests are in `test/statifier_router/basic_http_test.exs`, under
  "the location", "the front" and "the configuration".

One cite in "What bounds it" names code this Amendment's own change
moved. It reads `StatifierRouter.Delivery`'s private `create_options/1`
at `bb292c8`, where the Amendment says its cites are read, and there it
hands `create/4` the configuration's `:persistence_options` under
`initialize:` and nothing else. At `e38142f` that function is
`create_options/2`: it takes the delivery as well and, when the delivery
minted a token, hands `initialize:` the snapshot
`StatifierRouter.Config.create_persistence_options/2` rebuilds with
`location_token:`, which is the change the Amendment's own decision 4,
"How the token reaches the entry", decides. The sentence is true of the
code it cites, and this Note does not rewrite it.

Four sentences of that Amendment are amended in part by the Amendment on
the opt-in location table, which names them: "created by a new migration
version, `StatifierRouter.Migrations.V04`", "a host that does not use
BasicHTTP needs no migration", "a host that never sets the key does not
need V04", and "`StatifierRouter.Migrations` for the new version". Read
with that Amendment they hold at `e38142f`: V04 is the migration that
creates the table, and it is run outside the version walk.

**The Amendment on the opt-in location table.**

- Outside the walk: `StatifierRouter.Migrations`' private `@migrations`
  maps 1 to 3 only, `@package_columns` has no entry for 4, and the
  private `validate_version!/2` refuses a version of 4 as unknown.
- The two calls: `up_locations/1` and `down_locations/1` run
  `StatifierRouter.Migrations.V04` through the private
  `parse_locations!/1`, which reads the layout options and
  `:primary_key` with `up/1`'s private `layout!/1` and refuses `:from`,
  `:version` and any other key through `Config.reject_unknown/2`, raising
  `ArgumentError` before any DDL. The private
  `refuse_location_column_names!/2` refuses a leading `address_id`,
  `token` or `inserted_at`, and `id` under `:primary_key`.
- Tolerance: `V04.up/1` uses `create_if_not_exists` for the table and
  both indexes, and `V04.down/1` uses `drop_if_exists`.
- The rollback order: the moduledocs of `StatifierRouter.Migrations`
  ("The location table, V04, is opt-in") and of V04 say the opt-in
  migration rolls back first, and V01's `down` is unchanged.
- The tests: the migration tests on `main` before the change are
  unchanged; `test/support/bootstrap_migrations.ex` gains one opt-in
  migration at the end of its list; and
  `test/statifier_router/locations_migration_test.exs` covers "an
  uncapped first migration never creates V04, and rolls a pre-V04
  database back whole", "the documented opt-in migration rolls back
  before the first, and the database empties" and "a host that opts in
  from one migration gets the cascade and the unique token, and rolls
  back whole".

The 0.9.0 section of `CHANGELOG.md` names the key, the processor, the
front, the two calls and the opt-in table.

## Note (2026-09-30, sr-1rgb): the address sweep's writes run on SQLite

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. The Note of 2026-09-27 accepting the sr-w58a
Amendment says the private `stamp/3` and `delete/2` of
`StatifierRouter.Addresses` bind the ids in `fragment("? = ANY(?)",
a.id, ^ids)`. That form is Postgres's own; on SQLite the statement fails
with "no such function: ANY", so a host on SQLite could not reap its
address table from statifier_router 0.8.0 on.

Both functions now name their rows in `fragment("? IN (?)", a.id,
splice(^batch))`: an `IN` list with one bound parameter per id, which
Postgres and SQLite both take, written in batches of at most 500 ids a
statement (the private `in_batches/2` and `@ids_per_statement`), under
SQLite's smallest limit on bound parameters. Each id is still bound as
the table handed it over, so the Amendment's rule that the package
never casts an id it binds holds as before, and a reap answers the same
counts on Postgres as it did. The tests
`StatifierRouter.SQLiteReapTest` reap on SQLite under the default
integer key, under a text key of digits, and past one batch.

## Amendment (2026-10-02, sr-bpw3): a durable execution's outbound BasicHTTP send is performed after the delivery commits, and a failed POST comes back through deliver_event/4

Status: accepted

The Amendment of 2026-09-30 above on the BasicHTTP location ends its
decision 4 with "What is not decided here": "What an outbound BasicHTTP
send from a durable execution does at the executor seam, and whether its
delayed POST survives a resume, is statifier's processor and the
executor's, and is left to a later record." This Amendment decides the
first half for a send without a delay. The second half, the delayed
send, stays open (decision 5 below). The shape was ruled by the
operator, 2026-10-01:

> a durable execution's outbound BasicHTTP send is planned at the
> executor seam with `deliver/3` and performed with `perform/2` after the
> delivery commits, from a durable job keyed on the send's dedup key, as
> the recommended host pattern; the job insert belongs inside the
> delivery transaction; a failed after-commit POST reaches the execution
> only through `Delivery.deliver_event/4` with `create: :never` over the
> row from `Addresses.by_execution/2`; performing inline stays allowed,
> with its cost stated; no helper ships.

This Amendment changes no code. Code cites in this package are read at
`467c36d`; statifier cites at its `v2.10.0` tag; statifier_persistence
cites at 0.18.0, the version this package's `mix.lock` resolves.

**What bounds it.**

- **No session performs the send.** statifier_persistence hands each
  effect a step emits to the host's executor, once per effect, inside the
  step (`StatifierPersistence.Executor`'s `execute/2` callback), and at
  this package's seam that runs in the delivery's own process, inside its
  transaction (`StatifierRouter.Delivery`'s moduledoc, "What a route may
  not do while a delivery runs"). A durable execution has no
  `Statifier.Session` to plan or perform a send for it.
- **The processor plans and performs; it decides nothing more.**
  `StatifierRouter.BasicHTTP.deliver/3` and `perform/2` hand each call to
  `Statifier.Send.BasicHTTP` unchanged (decision 4 of the Amendment of
  2026-09-30). `Statifier.Send.BasicHTTP.deliver/3` is pure. For a send
  with a target it answers one instruction, `{:handler,
  Statifier.Send.BasicHTTP, {:post, post}}`, and for a delayed one
  `{:handler, Statifier.Send.BasicHTTP, {:post_after, delay_ms, post}}`;
  for a send with no target it answers `{:raise, :platform,
  "error.communication", origin, sendid: send_id}` and plans no request
  (st-ADR-0075, decision 4).
- **A failed POST names no durable execution.** `perform/2` makes one
  POST. On a transport error or a status outside 2xx it reports the miss
  through `Statifier.Session.failed_send/3` to a session it finds in
  `Statifier.Registry` under the plan context's `session_id`, and answers
  `{:error, reason}`; with no session registered there it answers
  `{:error, reason}` only, and the dead-letter rule of `failed_send/3`'s
  documentation is the host's (st-ADR-0075, decision 8, point d).
- **Every POST carries the send's dedup key.** The `scxml-send-key`
  header holds the eight fields of the send's dedup key, the first being
  the plan context's `session_id`, so a performed-again instruction sends
  the same value and a receiver that deduplicates on it sees the send
  once (st-ADR-0075's Amendment of 2026-09-30). This package's front is
  such a receiver (decision 5 of the Amendment of 2026-09-30).
- **An executor's error re-enters the step that emitted the send.** An
  `{:error, reason}` the executor answers for a send re-enters the
  execution as `error.communication`, carrying the send's `sendid`,
  inside the same step (`StatifierPersistence.Executions`' moduledoc,
  "Executor failures on actionable effects re-enter the chart"; its
  private `reentry_origin/1`).
- **An effect fired in a delivery that rolls back has happened.**
  ADR-0003's Consequences: "Effects fired inside a delivery that rolls
  back have happened anyway."

### 1. The send is planned at the executor seam

The host's executor, handed `{:send, %Statifier.Effect.Send{}}` whose
`type` is one of the two strings `StatifierRouter.BasicHTTP` is
registered under, plans it with `StatifierRouter.BasicHTTP.deliver/3`.
The event is `Statifier.Send.Event.build/2` of the send and the execution
id, and the plan context is `%{session_id: execution_id, opts: options}`,
where `execution_id` is the executor context's and `options` are the
configuration's `:basichttp` options, the keyword list
`StatifierRouter.Config`'s `basichttp` field holds. With the execution id as the
`session_id`, the first field of every `scxml-send-key` the send carries
is the execution id.

### 2. Recommended: performed after the commit, from a job inserted inside the delivery

- **The job is inserted at the seam.** For each `{:handler, module,
  payload}` instruction the plan answers, the executor inserts a job on
  the host's own repo. The executor runs in the delivery's process,
  inside its transaction, so the insert joins it: the job commits with
  the step that emitted the send, and a delivery that rolls back takes
  the job with it. This is the transactional outbox the README's "A
  transactional outbox, end to end" builds for a route, with the job row
  as the outbox row.
- **The job is keyed on the send's dedup key.** The job carries the
  instruction's payload, the plan context, the execution id and the
  send's id, under a key written from the send's dedup key components:
  the execution id, `send_id`, `macrostep`, `microstep`, `round`,
  `c_index`, `owner` and `ordinal`, any of which may be `nil` and is
  written as a fixed spelling of its own. A redriven step re-emits the same
  send with the same fields, so a uniqueness rule on that key keeps it to
  one job.
- **The job performs after the commit.** The job's worker calls
  `StatifierRouter.BasicHTTP.perform/2` with the payload and the plan
  context. It sees only committed jobs, so no POST is made for a step
  that rolled back, and it runs outside every delivery, so no
  transaction, no execution lock and no database write lock is held while
  the receiver answers. A job retried after a POST the receiver took
  sends the same `scxml-send-key`, which a deduplicating receiver answers
  without enqueuing twice.
- **Why it is the recommendation.** It is the one shape in which a slow
  or unreachable receiver costs the execution nothing but the failure
  itself, and in which no POST leaves for a step that never committed.

### 3. A failed POST reaches the execution only through `deliver_event/4`

When the job decides the send has failed - at once, or after the
retries its own policy allows - it reads the execution's address row
with `StatifierRouter.Addresses.by_execution/2` and delivers
`error.communication` through `StatifierRouter.Delivery.deliver_event/4`,
with:

- **The plan** `%{id: name, document: row.document, create: :never,
  dedupe: %{by: :message_id, horizon_ms: 259_200_000}}`. `name` is a
  string of the host's choosing that is no binding's `id` and is neither
  `execution` (ADR-0006, section 1) nor `basichttp` (decision 3 of the
  Amendment of 2026-09-30), so the ledger and dedupe rows the job writes
  are told apart from a binding's, an execution-to-execution send's and
  the front's; the README's recipe uses `basichttp_failure`. `create:
  :never` because a failure reaches an execution that exists and never
  makes one. The horizon is ADR-0001, section 1's default, the one the
  front takes.
- **The key** the row's `key`, and an envelope whose `scope` is the
  row's, whose `message_id` is the job's key, and whose `now` is the
  delivery's time. A job that delivers the failure twice is answered
  `{:duplicate, name}` the second time.
- **The event** `Statifier.Event.external("error.communication",
  sendid: send_id, data: data)`. Its `sendid` is the failed send's id,
  which the chart reads as `_event.sendid`; `data` is the host's, and the
  README's recipe carries the reason as a string. It reaches the
  execution through `step/5` as an external event, in a step of its own
  after the one that sent; a transition on `error.communication` matches
  it by name as it matches the in-step re-entry.

The answers, and what the job does with each:

| `deliver_event/4` answers | the job |
|---|---|
| `{:delivered, name, execution_id}` | is done |
| `{:duplicate, name}` | is done: an earlier attempt delivered it |
| `{:dropped, name, :finished}` | records a dead letter: the execution is terminal |
| `{:dropped, name, :no_execution}` | records a dead letter: the row was reaped between the read and the delivery |
| `{:error, reason}` | retries: the delivery did not settle |

A chart with no transition for `error.communication` in the state it is
in still answers `{:delivered, name, execution_id}`: `deliver_event/4`
does not take `dropped: unmatched_event` (`StatifierRouter.Delivery`'s
moduledoc), so the event is in the execution's input log and the job is
done, though no transition took it.

`by_execution/2` answering `nil` - an `:always_new` execution, which has
no address row (section 7), or a row already reaped - is a dead letter
too. The dead letter is `failed_send/3`'s rule, keyed by the send's dedup
key, with its reason.

This is the only sanctioned way back in. The job never calls
`StatifierPersistence.Executions.step/5` itself, which would skip the
dedupe claim, the ledger row and the address lookup every delivery
writes, and it has no session to call `failed_send/3` on.

- **The scope a route sees.** `deliver_event/4` sets no delivery scope,
  so in a step the job's delivery causes, a send to a route that some
  scope in `:route_overrides` overrides is refused as
  `{:no_delivery_scope, name}` (`StatifierRouter.SendHandler`'s
  moduledoc, "The scope a route is resolved in"). A chart whose
  `error.communication` handler sends to such a route meets that refusal
  on this path; this Amendment changes nothing about it.

### 4. Allowed: performed inline, inside the delivery

The executor may instead perform each planned instruction with
`StatifierRouter.BasicHTTP.perform/2` at the seam and answer its
`{:error, reason}`, which statifier_persistence re-enters as
`error.communication` in the same step, carrying the send's `sendid`. No
job and no `deliver_event/4` call is needed. The cost:

- The POST is made inside the delivery's transaction, so a slow receiver
  holds that transaction, the execution's lock and, on SQLite, the
  database's write lock for as long as it takes to answer.
- The POST leaves before the step commits. A delivery that then rolls
  back has POSTed anyway, and its redrive POSTs again with the same
  `scxml-send-key`; only a receiver that deduplicates on it sees the send
  once.

### 5. Neither shape covers a delayed send; that stays open

`Statifier.Send.BasicHTTP.perform/2` holds a delayed POST on a timer in
the process that performs the instruction, and at fire time POSTs only
if that process is a `Statifier.Session` still running (the moduledoc of
`Statifier.Send.BasicHTTP`, "A delayed send is this processor's timer").
At this package's seam it is not one. Whether a durable execution's
delayed BasicHTTP POST survives a resume, and so how one is performed,
is not decided here and is left to a later record. The README's recipe
refuses a `{:send_delayed, _}` of either type string at the executor
with an `{:error, reason}`, which re-enters the execution as
`error.communication`; that is the recipe's, not a decision on the open
question.

A send with no target plans the `{:raise, ...}` instruction above, which
no executor here performs; the recipe's executor answers `{:error,
reason}` for any instruction that is not `{:handler, module, payload}`,
and it re-enters the same way.

### 6. No helper ships

The recipe needs only public functions this package already has:
`StatifierRouter.BasicHTTP.deliver/3` and `perform/2`,
`StatifierRouter.Addresses.by_execution/2` and
`StatifierRouter.Delivery.deliver_event/4`. The job, its table or queue,
and its retry policy are the host's, as the drain of the README's outbox
is.

**What the Amendment of 2026-09-30 still says.** Its decisions 1 to 6
are unchanged: the token, rotation, resolution, the location string,
the front and the bearer capability. Its "What is not decided here" is
answered in its first half by this Amendment and stays open in its
second.

**Where it is shown.** No code changes. The README's "Sending from a
durable execution" shows the executor, the job and the failure path, and
`test/statifier_router/basic_http_send_test.exs` pins the failure path
against the package as it is: a failed POST delivered back through
`deliver_event/4` with `create: :never` over `by_execution/2`'s row steps
the execution on `error.communication` and finishes it, a retried job is
a duplicate, and a failure reaching a finished execution is
`{:dropped, name, :finished}`.

## Note (2026-10-02, sr-d2j1): the location token is kept out of this package's own query log

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Section 6 of the sr-xgi8 location Amendment
says to keep a location out of logs. At the `:debug` level Ecto's query
log prints every bound parameter, and three of this package's
statements bind the token, so a host running at `:debug` had the token
printed by this package's own statements. Ruled by the operator,
2026-10-01: those three statements run with Ecto's `log: false` option,
and nothing else changes.

- **The three statements.** The front's lookup, which the private
  `resolve/2` of `StatifierRouter.BasicHTTP.Front` runs over the query
  its private `address_by_token/2` builds; the location insert at
  create, in the private `locate/3` of `StatifierRouter.Delivery`; and
  the upsert in `StatifierRouter.BasicHTTP.rotate_location/2`. Each
  passes `log: false` to the repo call itself. No other statement in
  this package binds the token: `StatifierRouter.BasicHTTP.location/2`
  binds only the execution id and reads the token back as its result,
  which the query log does not print. No table, option, answer or
  transaction changes. The test is "the debug query log" in
  `test/statifier_router/basic_http_query_log_test.exs`.
- **The token is part of the execution's persisted state.** The
  location is written into the execution's `_ioprocessors` once, when
  the session starts (statifier 2.10.0, `Statifier.MachineState.new/2`;
  the moduledoc of `Statifier.Evaluator.SystemVariables`: "The entries
  are written here, once, when the session starts, and nowhere else"),
  and a persisted position carries it. statifier_persistence 0.18.0
  writes that position into `position_blob` on the create (the private
  `do_insert_execution/3` of `StatifierPersistence.Storage.Ecto`) and on
  every step (its `update_execution/2`), so the token is bound on those
  writes whatever this package does, and is at rest in the clear unless
  the host passes an encrypting `:blob_type` to that package. Ecto's
  inspect limit cuts the printed blob short, so the token is unreadable
  in those log lines, not absent from the parameters.
- **This package keeps the token out of its own query log only.** The
  statements of other packages are theirs. And `log: false` stops the
  log line, not the query telemetry event: in ecto_sql 3.14.0 (this
  package's `mix.lock`), the private `log/5` of `Ecto.Adapters.SQL`
  emits the repo's query telemetry event, with the bound parameters in
  its metadata, before it reads the `log` option, so a host's handler
  on that event still receives the token.
- **After a rotation.** The persisted `_ioprocessors` still names the
  old token, and the new token never enters `position_blob`. The
  location Amendment's "What rotation does not reach" bullet already
  says a chart reads the location it started with, which answers 404
  after a rotation.
- **The mitigation.** Rotate a location with `rotate_location/2` when it
  may have leaked, and never run a production repo or logger at
  `:debug`.

## Note (2026-10-02, sr-7zxe): the address sweep binds one array per batch on Postgres again

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. The sr-1rgb Note above moved the private
`stamp/3` and `delete/2` of `StatifierRouter.Addresses` to an `IN` list
of one bound parameter per id on every adapter. On Postgres that
statement's text varies with the batch's length, so Postgres prepared a
statement for each distinct length where the array form of 0.8.0 had
one. Ruled by the operator, 2026-10-01: the array form on Postgres, the
`IN` list on every other adapter.

- **The adapter branch.** The private `postgres?/1` reads the repo's
  adapter from its `__adapter__/0`. Only `Ecto.Adapters.Postgres` takes
  the array form; every other adapter takes the `IN` list, and so does a
  repo module that defines no `__adapter__/0` (one that delegates to an
  Ecto repo rather than being one).
- **The two forms.** On Postgres the private `stamp_query/2` and
  `delete_query/2` name the rows in `fragment("? = ANY(?)", a.id,
  ^batch)`: one bound parameter for the whole batch, so a write is the
  same statement whatever the batch's length. Elsewhere they name them in
  `fragment("? IN (?)", a.id, splice(^batch))`, the sr-1rgb form,
  unchanged.
- **The array's type.** The ids are bound as the table handed them over,
  never cast. Postgres types the parameter as an array of the id
  column's own type (`bigint[]` under the default key, `text[]` under a
  text key), and Postgrex encodes the list as that type, so a text id
  made of digits alone stays a string, as the sr-w58a Amendment's rule
  requires.
- **What does not change.** The batches stay at most 500 ids a
  statement on every adapter (the private `in_batches/2` and
  `@ids_per_statement`), and `reap/3` answers the same `stamped`,
  `deleted` and `next` as before. No option, table or answer changes.
- **The tests.** On Postgres, "binds each batch of ids as one array, so
  every batch of a write is one statement" in
  `StatifierRouter.PostgresReapTest` reads the statements from the
  repo's query telemetry event over a reap of three batches; on SQLite,
  "binds each batch of ids as a spliced IN list" in
  `StatifierRouter.SQLiteReapTest` does the same. "never casts a text id
  made of digits alone" in `StatifierRouter.PrimaryKeyTest` reaps under a
  text key of digits on Postgres.

## Note (2026-10-02, sr-n0y4): a late event after its address row is reaped, and the knob that decides it

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Section 5 keeps a finished execution's row
for the longest dedupe horizon of any enabled binding naming its
document, and the Consequences say that after the horizon a new event
for the same address opens a fresh execution. For an execution that
waits on more than one event, a partner that arrives after the reap
opens a second execution for the key under `create: :if_absent`. Ruled
by the operator, 2026-10-01: that trade is the host's, and this Note
names where the host sets it. No create mode that refuses a key seen
within the horizon, and no tombstone kept past the address row, is
added.

- **The knob is the dedupe horizon.** A row's reap horizon is the
  longest `dedupe.horizon_ms` of any enabled binding naming its
  document, computed from the bindings handed to each call of
  `StatifierRouter.Addresses.reap/3` (section 6). It is counted from
  `terminal_seen_at` (section 5), the first time this package read the
  execution's status as terminal, which is never earlier than the
  execution finished and can be later. So the first reap at or after
  `terminal_seen_at` plus the horizon deletes the row, and a row lives at
  least the horizon past the finish. A host whose latest partner can
  arrive later than that lengthens the horizon on any one binding naming
  the document. That binding's dedupe rows then live as long, since a
  claim's `expires_at` is the delivery's time plus the same `horizon_ms`
  (`StatifierRouter.Dedupe.claim/4`).
- **A document no enabled binding names has a horizon of zero.** Section
  6 says so, and it holds for a document reached only through the
  execution target (ADR-0006, section 2): its finished rows go at the
  next reap, whatever horizon the sender's own bindings carry.
- **What a late event meets, by the `create` of its binding.** The
  outcome names are ADR-0004's.

  | `create` | Before the reap deletes the row | After it |
  |---|---|---|
  | `if_absent` | `dropped: finished`, recorded against the finished execution, whose row is stamped if it was not yet (ADR-0003, section 4) | a second execution is created for the key and stepped with the event: `created_and_delivered` when the chart's initial state takes it, `dropped: unmatched_event` when it does not, and the second execution exists either way |
  | `never` | `dropped: finished`, as `if_absent` | `dropped: no_execution`; nothing is created |
  | `always_new` | a new execution | a new execution |

  `always_new` writes no address row (section 7), so there is no row
  for a reap to delete and no "before" or "after" for it: every event
  of that binding opens its own execution, at any time.
- **`create: :never` on the partner binding is the first-line answer.**
  A binding whose event only ever joins an execution another binding
  opened sets `create: :never`; after the reap its late event is the
  recorded drop `dropped: no_execution`, not a second execution. Its
  cost: an event of that binding that arrives before the opening event
  is dropped the same way and is lost, since nothing holds it until the
  execution exists. A host whose events can arrive in either order keeps
  `if_absent` and sets the horizon longer than the latest event it
  expects.
- **The tests.** `StatifierRouter.LatePartnerTest`
  (`test/statifier_router/late_partner_test.exs`) pins, over the parcel
  chart: the `if_absent` and `never` rows before and after the reap; for
  `always_new`, one execution per event and no row, with a reap between
  them that finds nothing; the longest enabled horizon as the knob, a
  disabled binding's horizon not counting; and the cost of
  `create: :never`. The horizon of zero for a document no enabled binding
  names is "a document no enabled binding names has a horizon of zero:
  its finished rows go at the next reap" in
  `StatifierRouter.CreateModesTest`; the execution-target case of it is
  not tested on its own.
- **Left open.** A create mode that refuses a key seen within the
  horizon, and a tombstone kept past the address row, are for a later
  record.

## Note (2026-10-02, sr-4llw): the outbound BasicHTTP send Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision,
amendment or Note above it. Records merge at proposed and are accepted
once their code has shipped in a published version and every claim they
make verifies against `main`, under the standing grant of the operator's
campaign consent of 2026-10-01. The `## Amendment (2026-10-02, sr-bpw3)`
on the outbound BasicHTTP send is such a record: its `Status:` line
moved from `proposed` to `accepted`. It changes no code; its recipe and
its test landed in PR 147 (`84f3c46`), and every function it relies on
shipped in statifier_router 0.10.0 (tag `v0.10.0`, at `f823adb`,
published on Hex 2026-10-02T11:42:49Z). The record's own status on line
3 was already `accepted` and was not touched, and the three Notes of
2026-10-02 between that Amendment and this Note carry no status.

Every claim was re-verified by anchor at `f823adb`, which is both the
tag and `main` at the time of the flip (the Amendment read this package
at `467c36d`); statifier cites at its `v2.10.0` tag and
statifier_persistence cites at 0.18.0, the versions `mix.lock` still
resolves. Three later changes touched files the Amendment cites, and none
changes a claim: the Note of 2026-10-02 on the query log (`log: false`
on the front's token lookup), the Note of 2026-10-02 on the address sweep
(the reap binds one array on Postgres), and ADR-0003's Amendment of
2026-10-02 (the front's delivery runs inside `:around_delivery`, and
`deliver_event/4` is still unwrapped and still sets no delivery scope).

- What bounds it: `StatifierPersistence.Executor`'s `execute/2`
  callback; `StatifierRouter.Delivery`'s moduledoc, "What a route may not
  do while a delivery runs"; `StatifierRouter.BasicHTTP.deliver/3` and
  `perform/2` hand each call to `Statifier.Send.BasicHTTP` unchanged.
  That module's `deliver/3` answers `{:ok, instructions}`, the list
  holding the one instruction the Amendment names for each case, which is
  how its "answers one instruction" reads. Its private `post_now/2` and
  `report/3` call `Statifier.Session.failed_send/3` only when
  `Statifier.Registry` holds a session under the plan context's
  `session_id`, and answer `{:error, reason}` either way; its private
  `send_key/2` writes the eight fields, `session_id` first, into the
  `scxml-send-key` header. `StatifierPersistence.Executions`' moduledoc
  and its private `reentry_origin/1` re-enter an executor's error as the
  Amendment says, and ADR-0003's Consequences carry the quoted line.
- Decision 1: `Statifier.Send.Event.build/2` takes the send and the
  session id; `StatifierRouter.Config`'s `basichttp` field is a keyword
  list or `nil`; `StatifierRouter.BasicHTTP` is registered under its
  `@uri` and `@short` strings.
- Decisions 2 and 4: the README's "A transactional outbox, end to end"
  and "Sending from a durable execution" show the job inserted at the
  seam, keyed on the send's dedup key fields, and performed after the
  commit; no code of this package's is involved.
- Decision 3: `StatifierRouter.Addresses.by_execution/2` answers the row
  or `nil`. `StatifierRouter.Delivery.deliver_event/4` under a `create:
  :never` plan answers `{:dropped, id, :no_execution}` from the private
  `absent/4`, `{:dropped, id, :finished}` from the private `finished/6`,
  and `{:duplicate, id}` on a duplicate claim; the private `taken/7`
  drops `unmatched_event` only for a `StatifierRouter.Binding` plan.
  `deliver_event/4` goes straight to the private `settled/5` and sets no
  delivery scope: only the binding path's private `delivered/4` and the
  front's private `deliver/5` set one, and `StatifierRouter.SendHandler`'s
  moduledoc, "The scope a route is resolved in", names
  `{:no_delivery_scope, name}`. The 72-hour horizon is ADR-0001, section
  1's default and the front's own; ADR-0006, section 1 reserves
  `execution` and the front's plan id is `basichttp`.
- Decision 5: `Statifier.Send.BasicHTTP`'s moduledoc, "A delayed send is
  this processor's timer", and its private `hold/4` POST only while the
  owner is a session still running; the README's recipe refuses a
  `{:send_delayed, _}` of either type string. The delayed send stays
  open, as the Amendment says.
- Decision 6: the four functions it names are public in 0.10.0, and no
  helper ships.
- Where it is shown: `test/statifier_router/basic_http_send_test.exs`,
  under "a failed after-commit send", pins the delivery of
  `error.communication` that finishes the execution, the retried job's
  `{:duplicate, "basichttp_failure"}`, and
  `{:dropped, "basichttp_failure", :finished}` for a finished execution.
