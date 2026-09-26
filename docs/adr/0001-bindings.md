# ADR-0001: Bindings: the schema, match and key as predicator programs over the normalized event, a three-valued match, the key refusal, one event to N bindings to N deliveries, data as a projection, and the reserved keys

Status: accepted

## Context

This package answers one question for every external event a host hands it:
which durable execution does this event belong to, and what event does that
execution receive? The answer is declared, not coded. A **binding** is the
declaration: it says which events it wants, how to compute the key that
names one execution among many, which document that execution belongs to,
and which event name the execution is handed. Every later piece of the
package (the address table, delivery, dedupe, the recorded outcomes) reads a
binding, so the binding's shape is the first thing to fix.

The four nouns are used each for itself here and in every later record. A
**document** is the stable thing an author edits and names. A **revision**
is one saved state of a document. A **chart** is what a revision compiles
to. An **execution** is one durable, stepped instance of one chart. A
workflow has executions.

Facts outside this package that bound the answer:

- **predicator compiles once and evaluates many times.** At predicator
  9.4.1, `Predicator.compile/1` turns an expression into an instruction
  list or returns `{:error, %Predicator.Errors.ParseError{}}`, and
  `Predicator.evaluate/3` takes that instruction list and a string-keyed
  context and returns `{:ok, value}` or `{:error, error}`. It returns errors
  rather than raising them.
- **predicator is three-valued.** `:undefined` is a first-class value: a
  missing map key or an out-of-range index reads as `:undefined` rather
  than failing (predicator's `docs/guides/nested-data-access.md`). Some
  opcodes propagate it (`compare` under a non-strict operator such as
  `==`, and the `in` and `contains` opcodes), some reject it with an
  error (`not`, the arithmetic operators, among others), and a strict
  `===` compares it like any other value.
  Its truth rule is that "true" means exactly
  `true`, and "falsy" means `false`, `null` or `:undefined` and nothing
  else (predicator's `docs/isa.md`: section 2 for these rules, and the
  `compare` subsection of section 5 for `===`).
- **An execution is created under an id its caller supplies.**
  statifier_persistence's `StatifierPersistence.Executions.create/4` takes
  the execution id as an argument (read at statifier_persistence 2e25130).
  So nothing below may lean on the store to tell executions apart: the
  router must know, before it creates anything, which execution an event is
  for. The binding supplies the key that the address record turns into
  that answer.
- **Sources are the host's.** The host already operates its queues,
  subscriptions and webhooks. A binding names a source; it does not
  implement one.

## Decision

### 1. The binding schema

A binding is given as a map or keyword list with exactly these keys, as
atoms. The enumerated values in the table (`:if_absent`, `:never`,
`:always_new`, `:message_id`, `:by_key`, `:none`) are atoms; `id`,
`source`, `document`, `event`, `match`, `key` and each `data` path are
strings.

| Key | Value | Required or default |
|---|---|---|
| `id` | a string, unique among the bindings a host hands the router in one configuration | required |
| `source` | a string naming a source adapter the host registers; this package registers none | required |
| `selector` | a map the source adapter reads to select its events; the router never reads it | default: the empty map |
| `match` | a predicator program (section 2) | required |
| `key` | a predicator program (sections 2 and 3) | required |
| `document` | the stable id of the document whose executions this binding addresses | required |
| `event` | the name of the chart event delivered to the execution | required |
| `data` | a list of field paths projected into the delivered event's data (section 5) | default: the empty list |
| `create` | `:if_absent`, `:never` or `:always_new` | default: `:if_absent` |
| `dedupe` | `%{by: :message_id, horizon_ms: h}`: deduplication on the event's message id, the only basis in this release, with a per-binding horizon `h`, a positive integer of milliseconds | default: `%{by: :message_id, horizon_ms: 259_200_000}` (72 hours) |
| `order` | `:by_key` or `:none` | default: `:by_key` |
| `enabled` | a boolean | default: `true` |

`document` is never a chart hash. A document keeps its id across revisions,
and new executions of a document start on whichever chart the host says is
active for it; a binding that named a chart hash would pin every new
execution to one compiled revision and defeat that. What `create`, `dedupe`
and `order` do when an event is delivered is the delivery record's to
decide; this record fixes only that they are keys of a binding, their
values, and their defaults. What the address table records for a binding
whose `create` is `always_new` is the address record's.

A binding with a missing required key, or with a value the table's Value
column does not allow, is refused when it is constructed, not when an
event first reaches it. A duplicate `id` is a fault of the configuration,
not of any one binding: it is refused when the host hands the router its
list of bindings, before any event is routed, and the refusal names the
duplicated `id`.

### 2. match and key are predicator programs over the normalized event

`match` and `key` are each compiled once, with `Predicator.compile/1`, when
the binding is constructed; a binding whose `match` or `key` does not
compile is refused then. At delivery they are evaluated over the
**adapter-normalized event**: the string-keyed map the source adapter hands
the router, bound in the evaluation context under the name `event`, so a
program reads `event.kind` or `event.impression_id`. The normalized event's
shape is the source adapter's contract; this record names only that it is a
map with string keys.

`match` is three-valued. A binding's match **holds** only when it evaluates
to exactly `true`. `false` and `:undefined` - and `nil`, predicator's
`null`, its one other falsy value - all mean "not for this binding": the
binding is skipped, and `:undefined` is never an error. A `match` whose
evaluation returns an error, or evaluates to any value other than `true`,
`false`, `nil` or `:undefined`, is a routing refusal recorded against the
binding.

### 3. The key refusal

`key` must evaluate to a non-empty string. Any other result is a routing
refusal recorded against the **binding**, never against an execution:
`:undefined`, `nil`, the empty string, a number, any other value, and an
evaluation error alike. For that binding and that event, no execution is
looked up, created or stepped. The router never invents a key; if the
binding's `key` does not produce one, there is nothing to address. The
names of the recorded outcomes, and where each is recorded, are the
outcome-vocabulary record's.

### 4. One event, N bindings, N deliveries

Every enabled binding for the event's source whose `match` holds gets its
own `key` evaluation and its own delivery. A source is not "for" a
document; a binding is. One event can therefore reach executions of several
documents, or several executions of one document under different keys, and
a refusal on one binding does not stop the delivery on another. A binding
whose `enabled` is `false` is not evaluated at all.

### 5. data is a projection, never the payload

`data` lists the fields of the normalized event, each named by a dotted
path relative to it, that the delivered chart event carries in its data,
under the same paths. Nothing else from the normalized event is delivered.
A path the event does not carry is left out of the delivered data rather
than refused, so a chart condition reading it sees predicator's
`:undefined`. The datamodel holds the scalars a chart's conditions need;
the full record stays in the source layer, where the host already keeps it.

### 6. Reserved keys and unknown keys

`mode`, `batch` and `window` are **reserved**: a binding carrying any of
them is refused at construction, and the refusal names the reserved key it
found. Batching and router-computed windows are out of scope in this
release; a later record may open them, and until one does, the three names
stay unavailable for any other meaning. Any other key not in the table in
section 1 is refused as unknown, naming the key.

### 7. Bindings are host configuration

A host constructs its bindings and hands them to the router; this package
stores none. How a binding is stored, and what versions it together with
the document it names, is a later record's. The address record says what
an address holds; nothing here says how a binding is kept.

### The example: an impression and its click

An ad impression opens an execution of the `impression_click_join`
document, and a click on the same impression lands on that same
execution. Two bindings, one document, one key:

```elixir
[
  %{
    id: "impressions_to_join",
    source: "ad_events",
    match: "event.kind == 'impression'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "impression",
    data: ["impression_id", "shown_at", "placement"]
  },
  %{
    id: "clicks_to_join",
    source: "ad_events",
    match: "event.kind == 'click'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "click",
    data: ["impression_id", "clicked_at", "url"]
  }
]
```

Both take the defaults for `selector`, `create`, `dedupe`, `order` and
`enabled`: one source carries both kinds of event, and `match` tells them
apart. A
normalized event `%{"kind" => "click", "impression_id" => "imp_7f3a",
"clicked_at" => "2026-09-19T08:00:00Z", "url" => "https://example.com/offer"}`
does not hold `impressions_to_join`'s match (it evaluates to `false`), holds
`clicks_to_join`'s, keys to `"imp_7f3a"`, and is delivered as the chart
event `click` with data `%{"impression_id" => "imp_7f3a", "clicked_at" =>
"2026-09-19T08:00:00Z", "url" => "https://example.com/offer"}`. A click that
arrives without an `impression_id` also holds `clicks_to_join`'s match, but
its key evaluates to `:undefined`: that is a key refusal recorded against
`clicks_to_join`, and no execution is touched.

## Consequences

- The binding is the whole routing declaration: a host changes where events
  go by changing bindings, not code, and every later record reads the
  binding's keys as fixed here.
- Every fault that can be seen without an event is refused before any
  event is routed: a missing or unknown key, a reserved key, an
  out-of-range value or a program that does not compile when the binding
  is constructed, and a duplicate id when the host hands the router its
  bindings. Only faults that depend on the event (a match or key that
  errors, a match that evaluates to a value other than `true`, `false`,
  `nil` or `:undefined`, a key that is not a non-empty string) are routing
  refusals at delivery.
- Sparse events are normal, not errors. Because `:undefined` does not hold
  a match, a binding written against a field an event lacks simply does not
  apply; because a key must be a non-empty string, an event that holds a
  match but lacks its key is refused on that binding and visible there,
  never silently delivered under an empty or made-up address.
- Refusals are the binding's, not an execution's. A misconfigured key shows
  up against the binding that computes it, where the host can fix it, and
  no execution carries a trace of an event that never reached it.
- Fan-out is explicit. A host that wants one event in two places declares
  two bindings; there is no implicit routing by source.
- The delivered event carries only the projected fields. A chart that needs
  another field needs a binding change; a chart never sees a payload it did
  not ask for.
- `mode`, `batch` and `window` cannot be given another meaning by a host in
  this release, so a later record that opens batching or windows starts
  from names no configuration has used.
- This record leaves to later records: what the address table holds and
  who mints the execution id; what `create`, `dedupe` and `order` do at
  delivery; the names and ledger of the recorded outcomes; and how bindings
  are stored and versioned with their document.

## Note (2026-09-21, sr-uce): what a dotted data path projects into, and the path that lands on a non-map

A Note, not an amendment: it decides nothing and changes no decision.
Section 5 stands as written. It says a `data` path is delivered "under
the same paths" without saying what a *dotted* path is delivered under,
and it names only the path the event does not carry. Both are recorded
here so the next reader does not have to derive them.

- **A dotted path projects into nested maps, not into a flat key.**
  `"placement.slot"` is delivered as `%{"placement" => %{"slot" =>
  value}}`, never as `%{"placement.slot" => value}`. The path is split
  on `.` and written segment by segment, and two paths sharing a prefix
  share the map at that prefix, so `["placement.slot",
  "placement.page"]` delivers one `"placement"` map holding both
  (`StatifierRouter.Binding`, `put_path/3`). This is the same shape
  predicator reads a dotted path in, so a chart condition written
  against `event.placement.slot` sees the value the binding named.
- **A path whose segment lands on a non-map is left out, exactly like a
  path the event does not carry.** Reading `"size.w"` out of an event
  whose `"size"` is the string `"300x250"` delivers nothing under
  `"size"`; the path is dropped and the rest of the projection is
  unaffected (`StatifierRouter.Binding`, `fetch_path/2`, whose
  non-map clause answers `:error`, which `project/2` folds as "skip").
  Section 5's consequence therefore covers this case too: the chart
  condition reading it sees predicator's `:undefined`, and no refusal
  is recorded.

## Note (2026-09-22, sr-6cs): accepted

A Note, not an amendment: it decides nothing and changes no decision above
it. The status on line 3 was flipped from `proposed` to `accepted` on the
operator's word of 2026-09-22, after statifier_router 0.2.0 was published.

Every claim this record makes about the package was re-verified at
`0cea19c` before the flip: the binding schema, its defaults and the order
of the construction refusals against `StatifierRouter.Binding`, `new/1`;
the three-valued match against `StatifierRouter.Binding`, `match/2`; the
key refusal against `StatifierRouter.Binding`, `key/2`; the projection and
the dropped path against `StatifierRouter.Binding`, `project/2`; the
duplicate-id refusal against `StatifierRouter.Config`, its
`{:duplicate_binding_id, id}` refusal; the fan-out over enabled bindings of
the event's source against `StatifierRouter`, `route/3`; and the absence of
any binding storage against the package's schemas, which hold addresses,
dedupe rows, the ledger and subscriptions and no binding. The two external
facts in Context were re-read at the versions this release pins:
`Predicator.compile/1` and `Predicator.evaluate/3` at predicator 9.4.1, and
the caller-supplied execution id at `StatifierPersistence.Executions`,
`create/4`, at statifier_persistence 0.13.0. Predicator's own guide files
are not shipped in its hex package, so the three-valued rules cited from
them were re-verified against predicator's shipped `Predicator.Undefined`,
which owns the `:undefined` sentinel and keeps it apart from `nil`, and
against this package's own `match/2` tests "holds only for its own kind of
event", "returns :undefined when the field it reads is missing" and
"returns false when the program evaluates to nil", which pin `true`,
`false`, `nil` and `:undefined` each to the answer section 2 gives it.

No sentence in the body speaks of this record's own status, so nothing
above this Note was edited.

The status cell for this record in `docs/adr/README.md` is flipped by a
separate bead after all seven records; the index lags by design until then.

## Amendment (2026-09-25, sr-h27): the binding set as a function of scope, exclusive with the static list

Status: accepted

Section 7 has the host hand the router its bindings, and until now it
handed one list, `:bindings`, read the same for every scope. A host whose
scopes each route their own sources to their own documents has had to put
every scope's bindings in that one list, with nothing to keep one scope's
events off another's bindings. This Amendment lets the binding set depend
on the scope. Sections 1 to 6 stand: a binding's schema, its programs,
its refusals and its fan-out are unchanged, and only where the list comes
from changes.

- **The key and its behaviour.** `StatifierRouter.Config` takes an
  optional `:bindings_resolver`: a module implementing the one-callback
  behaviour `StatifierRouter.BindingsResolver`, whose `resolve/1` takes a
  scope and answers a list of `%StatifierRouter.Binding{}` structs, or an
  arity-1 fun with that signature. `Config.new/1` checks it as it checks
  `:resolver`: a fun of the right arity, or a loadable module exporting
  the callback, and refuses any other value with
  `{:error, {:invalid_value, :bindings_resolver, value}}`. A `nil` value
  is the key left out.
- **Exclusive with the static list.** A configuration that gives both
  `:bindings` and a `:bindings_resolver` is refused with
  `{:error, {:exclusive_keys, :bindings, :bindings_resolver}}`, whatever
  the `:bindings` value, the empty list included, so neither silently
  wins. A configuration with a resolver keeps `bindings: []`.
- **Called at match time, per scope.** `StatifierRouter.route/3` asks the
  resolver once per call, with the event's scope, after the event and the
  options are checked and before any binding is evaluated; the answer
  then plays the part the static list plays, in the order given
  (sections 1 and 4). Caching is the host's: nothing in this package
  keeps an answer between calls.
- **Each answer is checked as the list is.** Section 1 refuses a
  duplicated `id` when the host hands the router its bindings; for a
  resolver that moment is every answer. An answer carrying a binding
  under the reserved execution-target name is refused with
  `{:reserved_binding_id, name}` and one carrying a duplicated `id` with
  `{:duplicate_binding_id, id}`, the terms `Config.new/1` refuses the
  static list with; `route/3` returns either as `{:error, reason}` before
  any binding is evaluated, so nothing is written (ADR-0004, section 7).
  An answer that is not a list of built bindings raises `ArgumentError`,
  as a malformed `:resolver` answer does. The structs are trusted as
  `StatifierRouter.Binding.new/1` built them, as a prebuilt struct in the
  static list is.
- **Reader by reader.** Five places read the binding set, and each does
  one thing under a resolver:
  - `route/3`, the matcher, reads the answer for the event's scope, as
    above.
  - The Broadway partitioner has the event's scope in hand and reads the
    answer for it; an answer the checks above refuse is partitioned by
    the message id, as an unaddressable message is, and `route/3` fails
    the message.
  - `subscribe/3` has no event, so it reads the scope from the
    subscribing execution's address row and looks for the binding in the
    answer for that scope. The row is therefore read before the binding
    is checked, and an execution with no row is refused as
    `{:unaddressed_execution, id}` whether or not the binding exists. An
    answer the checks refuse raises `ArgumentError`, because this
    function's return names only its two refusals.
  - The publish-time checks (ADR-0008) take no scope. `check/3` reads the
    configuration's `bindings: []`, so its `:undeclared_binding_events`
    is empty under a resolver, and a host checks each scope's answer with
    `undeclared_binding_events/2`, as ADR-0008, decision 2 already has a
    host whose declarations differ by scope do. That decision says a
    binding applies in every scope its events carry; that holds for the
    static list, and under a resolver a binding applies in the scopes
    whose answer carries it.
  - The address reaper (ADR-0002, sections 5 and 6) has always taken the
    host's bindings as its own argument rather than the configuration's.
    A host with a resolver hands it the bindings of every scope it
    routes; a row's horizon is read by document alone, so a document
    bound in several scopes keeps the longest horizon among them.
- **Absent is today.** With no `:bindings_resolver`, every reader reads
  `:bindings` exactly as before this Amendment, `subscribe/3` included:
  it checks the binding before it reads the address row, as it always
  has.

**Where the code is.** `StatifierRouter.BindingsResolver`, the behaviour;
`StatifierRouter.Config`, whose `binding_source/1` checks the two keys and
whose `bindings_for/2` answers the binding set of one scope with the
checks above; `StatifierRouter`, whose `route/3` and `subscribe/3` read
it; and `StatifierRouter.Broadway`, whose `partition/3` reads it; in the
pull request that carries this Amendment. The bindings resolver tests pin
two scopes answering different bindings for one source and the refusal of
both keys together.

## Note (2026-09-25): the sr-h27 Amendment accepted

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. The operator accepted the `## Amendment (2026-09-25,
sr-h27)` on 2026-09-25, and its `Status:` line moved from `proposed` to
`accepted`. Its code landed in PR 89 (`da78b5f`) and shipped in
statifier_router 0.6.0 (tag `v0.6.0`, at `0854a99`). The record's own
status on line 3 was already `accepted` and was not touched.

Every claim was re-verified by anchor at `0854a99`, which is both the
tag and `main` at the time of the flip:

- The behaviour is `StatifierRouter.BindingsResolver`
  (`lib/statifier_router/bindings_resolver.ex`).
- `StatifierRouter.Config`'s private `binding_source/1` checks the two
  keys, and its `bindings_for/2` answers the static list when no
  resolver is set and asks the resolver otherwise.
- `StatifierRouter.Broadway`'s `partition/3` reads the binding set of the
  event's scope.
- The tests are in `test/statifier_router/bindings_resolver_test.exs`.

Under a resolver, `check/3` reads `bindings: []`, so its
`:undeclared_binding_events` is empty whether or not any binding was
checked, as the reader list above says. sr-9fud makes that visible in the
report; it lands with a later Note on this record and does not hold this
flip.

## Note (2026-09-26, sr-9fud): the spelling of the marker that `check/3` did not check the bindings

A Note, not an amendment: it decides nothing and changes no decision or
amendment above it. It is the later Note the Note above names.

The operator ruled on 2026-09-25 that under a `:bindings_resolver`,
`check/3`'s report carries an explicit marker that the binding check did
not run, and left the spelling to a record. ADR-0008's Amendment of
2026-09-26 decides it, at `proposed`: the first entry of `check/3`'s
`unchecked` list is `%{reason: :bindings_resolver, location: nil}`, the
one entry of that list with no location, typed
`t:StatifierRouter.Contracts.bindings_unchecked/0`. A configuration with
no resolver gets no such entry.

The reader list of the 2026-09-25 Amendment stands otherwise: `check/3`
reads `bindings: []` and never calls the resolver, its
`:undeclared_binding_events` is empty under one, and a host checks each
scope's answer with `undeclared_binding_events/2`. The code is
`StatifierRouter.Contracts`'s `check/3` and its private
`bindings_unchecked/1`, in the pull request that carries ADR-0008's
Amendment.
