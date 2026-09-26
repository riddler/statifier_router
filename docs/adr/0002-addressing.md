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
