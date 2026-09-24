# ADR-0008: The receiver contract at publish: an execution-target send's literal event and a binding's event are checked against the receiving document's declaration through a host-supplied lookup, a receiver that declares nothing is judged by the engine's computed vocabulary, what cannot be read from a literal is reported unchecked, an unpublished receiver is a finding of its own, and the package ships pure functions the host's publish step calls

Status: accepted

## Context

Two things in this package name an event that another document's chart is
expected to take, and nothing checks either name against that document.

- **A binding names one.** A binding's `document` and `event` are required
  non-empty strings (ADR-0001, section 1; `StatifierRouter.Binding`'s
  moduledoc table and `new/1`, read at `f7ac0e2`). Every event the binding
  routes reaches an execution of `document` as a chart event named
  `event`.
- **An execution-target send names one.** A `<send>` whose `type` is the
  host's registered processor and whose `target` is the reserved name
  `execution` delivers its `event` to the execution its `document` and
  `key` params address, in the sender's own scope (ADR-0006, sections 1
  and 4). The reserved name is `StatifierRouter.SendHandler.execution_target/0`
  (read at `f7ac0e2`).

When either name is one the receiving chart never listens for, nothing
refuses it. ADR-0004, section 8 keeps `dropped: unmatched_event` out of
the release: an event the execution's current state has no transition for
is taken by `step/5` and recorded as delivered or created_and_delivered.
The engine does the same one level down: an event that matches no
enabled transition changes no configuration and raises nothing
(st-ADR-0071, `docs/adr/0071-chart-event-vocabulary-and-accepts-check.md`
in statifier-ex, decision 6). A misspelt binding therefore delivers
forever and moves nothing, and the ledger says delivered each time.

Facts outside this record that bound the answer:

- **The route check already exists, and it is the shape to follow.**
  `StatifierRouter.Routes.unregistered/2` (read at `f7ac0e2`) is the
  publish-time check ADR-0005, section 7 owed: pure and total over a
  resolved `StatifierRouter.Config` and a compiled machine, answering
  `%{unregistered: [...], unchecked: [%{reason, location}]}` in `c_index`
  order, with `:typeexpr` and `:targetexpr` as the reasons a send could
  not be judged. It never reports the reserved execution target.
  `StatifierRouter.Routes.unsupported_types/2` composes the engine's
  `Statifier.Send.Types.unsupported_sends/2` over the configuration's
  snapshot. This record adds the third check beside those two and
  composes all three.
- **A `<send>`'s params are never literal on the compiled machine.** In
  statifier 2.6.0, the version this package's `mix.lock` resolves,
  `Statifier.Machine.Content.Send` holds `event`, `target` and `type` as
  `{:static, value}` for the literal attribute or `{:compiled, _, _}` for
  its `*expr` sibling, and holds `params` and `namelist` as separate lists
  of `Statifier.Machine.Param`. A `<param>` element's `expr` is always
  the compiled form, `{:compiled, %Predicator.Compiled{}, source}`,
  whether the author wrote `expr` or `location` (its `kind` says which);
  only a `namelist` entry may instead carry `{:invalid, error}`, when it
  failed to compile (`Statifier.Machine.Param`'s `expr` type). An author
  who writes `expr="'parcel'"` gets compiled instructions that are the one
  instruction `["lit", "parcel"]`; an author who writes `expr="doc_id"`
  gets `["load", "doc_id"]`. Decision 1 defines "literal" over that.
- **The engine decides the vocabulary and the membership question.**
  st-ADR-0071 (proposed) decides `Statifier.Chart.events/1`, the
  descriptors on transitions from states that can be active, and
  `Statifier.Chart.check_accepts/2`, which compares a declared name list
  with that vocabulary under the runtime's own descriptor matching. Its
  decision 4 answers membership for a receiver that declares nothing:
  `check_accepts(machine, [name])` answers `unreachable: []` when some
  reachable descriptor matches `name` and `unreachable: [name]` when none
  does. Its "does not decide" list leaves "a receiver-side check at
  delivery time, for a host that routes events between executions" to
  this package's own record, and says its decision 4 gives that record
  the membership answer. This record asks the same question at publish
  rather than at delivery; the delivery-time half is ADR-0004, section
  8's deferred outcome (decision 5). `Statifier.Chart.events/1` is on
  statifier-ex main (read at
  `f344cc9`); `check_accepts/2` is decided and not yet on main; neither is
  in a published statifier release.
- **A document format may carry the declaration.** statifier_blocks'
  sb-ADR-0014 (`docs/adr/0014-document-accepts-declaration.md` in
  statifier_blocks, proposed, read at `78bf210`) puts an optional
  `accepts` list of event names on a block document's envelope and
  carries it onto the compiled artifact. Its decision 5 reads an empty
  or absent list as "no declaration", under which the computed vocabulary
  is the contract, and its "does not decide" list leaves "refusing a
  binding that names an undeclared event" to this package's record. This
  package does not depend on statifier_blocks and does not start to: a
  declaration reaches it as a plain list of names (decision 2).
- **The host's resolver is keyed by `(scope, document)`.**
  `StatifierRouter.Resolver`'s `resolve/2` callback (read at `f7ac0e2`)
  answers `{content_hash, machine}` or `{:error, term()}`; the
  `{:error, :not_published}` in its moduledoc is an example host's reason,
  not a term the package defines. The resolver is called at delivery,
  when an event has brought its scope with it (ADR-0003, section 8). A
  publish carries no event.

The records of this package this one reads are the bindings record
(`docs/adr/0001-bindings.md`), the addressing record
(`docs/adr/0002-addressing.md`), the delivery record
(`docs/adr/0003-delivery-discipline.md`), the outcome vocabulary
(`docs/adr/0004-the-refusal-and-drop-vocabulary.md`), the routes record
(`docs/adr/0005-routes.md`) and the execution-target record
(`docs/adr/0006-the-execution-target.md`).

## Decision

### 1. What is checked, and what "literal" means

Two kinds of name are checked, each against the document it is sent to.

- **An execution-target send.** A `<send>` in the machine being published
  whose `type` is `{:static, t}` with `t` the configuration's
  `:send_type`, and whose `target` is `{:static, n}` with `n` equal to
  `StatifierRouter.SendHandler.execution_target/0`. That is the literal
  part of the set `StatifierRouter.SendHandler` will hand to ADR-0006's
  delivery at run time, where it selects on the resolved `type` and
  `target`, so a send written with `typeexpr` or `targetexpr` may be
  handed too (decision 3 says where those are reported). Judging only the
  configuration's own type follows the reasoning `Routes.unregistered/2`'s
  `@doc` gives. Such a send is judged when
  its `event` is `{:static, name}` and its `document` param is literal.
- **A binding.** Every `%StatifierRouter.Binding{}` in the configuration's
  `:bindings`. Its `document` and `event` are already literal strings, so
  every binding is judged and none is unchecked.

**A literal `document` param** is exactly this: the send's `params` hold
exactly one `%Statifier.Machine.Param{}` named `document`, its `namelist`
holds none, its `kind` is `:expr`, and its compiled instructions are
exactly one instruction `["lit", value]` with `value` a non-empty string.
`value` is the receiving document id. Anything else is not guessed at:
decision 3 reports it.

### 2. The receiver's declaration reaches the package through a host-supplied lookup, and the check is membership

The host supplies a lookup, an arity-1 function from a document id to
one of three answers:

    (document :: String.t() ->
       {:ok, [String.t()]}
       | {:ok, :undeclared, Statifier.Machine.t()}
       | {:error, :not_published})

- **`{:ok, names}`: the receiver declares these names.** The event is
  accepted when it is equal, as a string, to one of `names`. A declared
  entry is a name, not a descriptor (st-ADR-0071, decision 3), and the
  sent event is a name, so equality is the whole relation. An empty list
  is a declaration that accepts nothing, which is st-ADR-0071 decision
  3's reading of `[]`.
- **`{:ok, :undeclared, machine}`: the receiver declares nothing.** Its
  contract is the engine's computed vocabulary, and the event is accepted
  when `Statifier.Chart.check_accepts(machine, [event])` answers
  `unreachable: []` (st-ADR-0071, decision 4). The package does not
  re-implement descriptor matching over `Statifier.Chart.events/1`'s
  strings; the engine's function is the one relation. `machine` is the
  chart the host would start a new execution of that document on, the
  one its resolver would answer.
- **`{:error, :not_published}`**: decision 4.

A host whose document format reads an empty list as "no declaration",
as sb-ADR-0014 decision 5 does, answers `{:ok, :undeclared, machine}` for
such a document. That translation is the host's, because the format is
the host's; the package reads the three answers above and nothing else.
Any other answer is the host's fault and the function raises, as
`StatifierRouter.Delivery`'s `resolve/3` raises for a resolver answer
outside its type.

**The lookup takes no scope, and the scope enters by the host's
construction.** A publish is not an event and carries no scope; the
scope rides with an event (ADR-0003, section 8), which is why the
resolver takes one and this lookup does not. The host knows which scope
it is publishing into, so it builds the lookup over that scope's active
revisions. For an execution-target send that is also the only scope the
send can reach, because the receiver is always in the sender's scope
(ADR-0006, section 1). A binding applies in every scope its events carry,
so a host whose declarations differ by scope calls the binding check
once per scope, with one lookup each. The package never learns what a
scope means (ADR-0002, section 2).

**A finding says which contract refused it.** A refusal under a
declaration has reason `:undeclared`; a refusal under the computed
vocabulary has reason `:undeclared_by_computed_set`, so a host can tell
an author "the receiving document does not declare this" from "the
receiving document declares nothing, and its chart never listens for
this".

### 3. What cannot be checked is reported unchecked, with its location and a named reason

A send that decision 1 selects but cannot judge is never a finding and
never passed silently. It is reported on an `unchecked` list as
`%{reason: reason, location: location}`, `location` being the `<send>`
element's, which is the shape `Routes.unregistered/2`'s `:unchecked`
entries have. The reasons:

| Reason | Means |
|---|---|
| `:eventexpr` | the send's event is `{:compiled, _, _}`, written as `eventexpr` |
| `:no_event` | the send writes neither `event` nor `eventexpr` |
| `:document_expr` | a `document` is present and is not a literal by decision 1: an expression other than one `lit` of a non-empty string, a `location`, a `namelist` entry, or more than one param named `document` |
| `:no_document` | no `document` param and no `namelist` entry of that name |

The reasons `:typeexpr` and `:targetexpr` are not repeated here. A send
whose `type` or `target` is an expression is not selected by decision 1,
and `Routes.unregistered/2` already reports it under those reasons; the
composition of decision 6 carries that list once. A `:no_document` send
is also a run-time refusal, `send_refused` with reason `document`
(ADR-0006, section 6); reporting it unchecked here says only that this
check could not name a receiver, and decides nothing about a publish-time
check of ADR-0006's envelope.

### 4. An unpublished receiver is a finding of its own

When the lookup answers `{:error, :not_published}`, the send or binding
names a document with nothing to judge against, and that is a finding
with reason `:not_published`, not an unchecked entry. It is a finding
rather than a gap because its run-time result is already known: a
delivery that would create an execution of that document, from an
execution-target send or a binding, asks the resolver for the document's
chart, and a resolver with no chart answers `{:error, reason}`, which the
delivery surfaces as
`{:error, {:unresolved_document, document, reason}}` (ADR-0003, the Note
of 2026-09-20; `StatifierRouter.Delivery`'s `resolve/3`, read at
`f7ac0e2`).

### 5. The runtime backstop does not exist yet, and this record says what refuses today

The backstop this check stands in front of is ADR-0004, section 8's
`dropped: unmatched_event`, and that outcome is deferred: no record adds
it and no code produces it. Today, at run time:

- **An event the receiver's chart never takes is not refused.** It is
  delivered or created_and_delivered, and recorded so (ADR-0004,
  section 8), and the receiver's step selects no transition
  (st-ADR-0071, decision 6).
- **A receiver with no published chart is refused only at a create.**
  The resolver's `{:error, reason}` surfaces as
  `{:error, {:unresolved_document, document, reason}}` (decision 4): for
  a binding, as `StatifierRouter.route/3`'s error, which is not an
  outcome (ADR-0004, section 7); for an execution-target send, as the
  handler's `{:error, reason}`, re-entered in the sender as
  `error.communication` (ADR-0006, section 3). An existing execution is
  stepped on the chart it started on and asks the resolver nothing
  (ADR-0002, the Amendment of 2026-09-19).

So this check is, today, the first line and the only one for an event
name. **What a later drop would mean, said plainly.** This check answers
whether the receiving chart can ever take a name; `dropped:
unmatched_event`, as ADR-0004, section 8 describes it, answers whether
the execution's current state takes it. Once that outcome exists, a drop
of a literal name in a state that does not take it, while another
reachable state does, is the ordinary outcome and not a fault of this
check. A drop of a literal name that no reachable transition of the
receiver's chart matches, sent by a send or a binding this check passed,
is not by itself a bug either, in three cases:

- **Revision drift.** This check judges the chart a new execution of the
  receiving document would start on, the one the host's lookup and
  resolver answer. An existing execution is stepped on the chart it
  started on, named by its content hash (ADR-0002, the Amendment of
  2026-09-19), so an execution started on an earlier revision may not
  take a name the current revision takes.
- **Host policy.** `Statifier.Chart.check_accepts/2` reports and refuses
  nothing, and which of its lists a host refuses a publish on is the
  host's decision (st-ADR-0071, decision 3). A receiver published with a
  declared name its chart cannot take is the host's choice, not a check
  that failed.
- **Scope.** Decision 2 leaves it to the host to run the binding check
  once per scope. A binding checked against one scope's lookup and
  delivered in another scope, whose declarations differ, was never judged
  for that scope.

A drop means a publish check has a bug - this one, or the receiver's own
check of its declaration - only when the execution is stepped on the
revision this check judged, in the scope it judged, and the host refuses
a publish on `unreachable`. A drop of a name this check reported
unchecked is the gap decision 3 already named.

### 6. The package ships pure functions; the host's publish step calls them

This package gains no publish step, no publish store and no process. The
functions below are pure over their arguments: they read a resolved
configuration, a compiled machine and the host's lookup, and the lookup
is the only call that reaches outside them, and it is the host's. A host
calls them when it saves a revision, when it compiles a document in CI,
or when an author presses publish, and decides for itself whether a
finding blocks the publish or warns, exactly as `Routes.unregistered/2`'s
moduledoc says of that check. An editor calls the same functions at edit
time. Nothing is added to `Statifier.Validator`, whose `validate/3` takes
no deployment state (st-ADR-0069,
`docs/adr/0069-host-registered-send-types.md` in statifier-ex, decision
3).

**No dependency on statifier_blocks, in either direction.** The lookup's
answers are a list of strings and a compiled `Statifier.Machine`; a host
that keeps block documents reads its own `accepts` list and hands the
list over. The engine is this package's dependency already; the
engine's release that carries `Statifier.Chart.check_accepts/2` is the
floor the code half needs.

**The surface the code half builds**, in a new module
`StatifierRouter.Contracts`:

- `undeclared_events(config, machine, lookup)` answers
  `%{undeclared: [finding], unchecked: [unchecked]}`, both in `c_index`
  order. A finding is `%{event, document, location, reason}` with
  `reason` one of `:undeclared`, `:undeclared_by_computed_set` and
  `:not_published`; an unchecked entry is decision 3's.
- `undeclared_binding_events(bindings, lookup)` answers a list of
  `%{event, document, binding_id, reason}` with the same three reasons,
  in the order of `bindings`.
- `check(config, machine, lookup)` answers one report under five named
  keys: `unsupported_types`, `Routes.unsupported_types/2`'s list;
  `unregistered_routes`, `Routes.unregistered/2`'s `unregistered` list;
  `unchecked`, `Routes.unregistered/2`'s and `undeclared_events/3`'s
  unchecked entries together, in document order; `undeclared_events`,
  `undeclared_events/3`'s findings; and `undeclared_binding_events`,
  `undeclared_binding_events/2` over the configuration's `:bindings`.
  Both route functions are composed unchanged.

### The example: a depot system names an event the parcel never declared

A parcel is scanned from depot to doorstep. The host publishes a document
`parcel`, whose chart moves from `at_depot` to `in_transit` on
`parcel.scanned` and from `in_transit` to `delivered` on
`parcel.delivered`, and declares exactly those two names:

    lookup = fn
      "parcel" -> {:ok, ["parcel.scanned", "parcel.delivered"]}
      _other -> {:error, :not_published}
    end

The depot system's feed is bound three times. Two bindings name
`parcel.scanned` and `parcel.delivered`. The third, `depot_lost`, routes
the depot's missing-parcel report to the parcel as `parcel.lost`.
`undeclared_binding_events/2` answers

    [%{event: "parcel.lost", document: "parcel", binding_id: "depot_lost",
       reason: :undeclared}]

and the host refuses the configuration. Without this check that binding
would deliver every report, the ledger would record delivered each time,
and no parcel would ever leave `in_transit` for it.

A `delivery_round` document, the courier's round for one day, tells each
parcel when it reaches the door:

    <send type="myapp:router" target="execution" event="parcel.delivered">
      <param name="document" expr="'parcel'"/>
      <param name="key" expr="parcel_id"/>
    </send>

Its `document` param compiles to the one instruction `["lit", "parcel"]`,
so decision 1 reads the receiver as `parcel`, and `parcel.delivered` is
declared: no finding. Had the send written `eventexpr="outcome"`, it
would be reported unchecked with reason `:eventexpr`; had the `document`
param been `expr="receiver"`, with reason `:document_expr`.

Had the host published `parcel` with no declaration, the lookup would
answer `{:ok, :undeclared, machine}`, `check_accepts(machine,
["parcel.lost"])` would answer `unreachable: ["parcel.lost"]`, and the
`depot_lost` finding would carry reason `:undeclared_by_computed_set`.

### Enumeration is a test's, not this record's

Which sends a given chart writes, which reason a given send earns, and
that every path above lands the entry it names are enumerated by the
code half's tests, not claimed here over a live codebase.

## What this record does not decide

- **A publish-time check of ADR-0006's envelope.** Whether an absent
  `document` or `key`, or a literal `create` naming a mode ADR-0006 does
  not offer, becomes a finding of its own is left to a later record.
- **The receiver's own consistency.** Whether a declared name is one the
  receiving chart can take is the receiver's publish check
  (st-ADR-0071, decision 3; sb-ADR-0014, decision 4), run when the
  receiver is published, not by this package.
- **Payload shape.** A declaration names events; what they carry is not
  checked.
- **Where a declaration is stored or how a host indexes it.** The
  lookup's answers are the whole interface.
- **`dropped: unmatched_event`.** Its spelling, its ledger row and when it
  lands stay ADR-0004, section 8's deferral.
- **Which finding blocks a publish.** That is the host's decision, as it
  is for the route check.
- **Sends of any type other than the configuration's own, and a route's
  sink.** A route is one-way and names no receiving document (ADR-0005,
  section 3).

## Consequences

- A binding that names an event its document does not accept, and an
  execution-target send whose literal event its receiver does not accept,
  are found before anything is delivered, from data the host already
  has.
- A host that wants the stricter contract requires a declaration on
  every document a binding or a send can reach. A host that does not
  gets the engine's computed vocabulary, which over-counts and never
  under-counts (st-ADR-0071, decision 2), so the fallback can pass a name
  a guarded transition never actually takes and never refuses one some
  reachable transition matches.
- A send whose receiver or event is an expression is visible as
  unchecked, with its location, instead of passing silently.
- The code half waits for a published statifier release carrying
  `Statifier.Chart.check_accepts/2`; until then the computed-vocabulary
  fallback has no function to call, and this package does not write one.
- `StatifierRouter.Contracts` is a new public module with three
  functions, and `check/3` becomes the one call that runs every
  publish-time check this package ships.

## Note (2026-09-22, sr-fon): the engine release the Context waited for is published

This Note records facts that changed after the record was written. It
decides nothing, and no line above it was edited.

The Context and the Consequences were written against statifier 2.6.0,
and the sentences below, in four groups, describe the state of the day
the record was written, where each was true:

- **The resolved engine.** The Context says statifier 2.6.0 is "the
  version this package's `mix.lock` resolves". At `2d053d5`, `mix.exs`
  requires `{:statifier, "~> 2.7"}` and `mix.lock` resolves statifier
  2.7.0, published to Hex and tagged `v2.7.0` in statifier-ex. The shape
  of `Statifier.Machine.Content.Send` and `Statifier.Machine.Param` the
  same paragraph describes holds unchanged at 2.7.0: `event`, `target`
  and `type` are each typed `Statifier.Machine.expr() | nil` in
  `Statifier.Machine.Content.Send`'s `t/0`: `{:static, value}`,
  `{:compiled, compiled, source}`, or `nil` when the author wrote neither
  the attribute nor its `*expr` sibling; `params` and `namelist` are lists of
  `Statifier.Machine.Param`; and only a `namelist` entry may carry
  `{:invalid, error}` (the `expr` typedoc of `Statifier.Machine.Param`).
  Compiled at 2.7.0, the section's two examples give the one
  instruction `["lit", "parcel"]` for `expr="'parcel'"` and
  `["load", "doc_id"]` for `expr="doc_id"`.
- **Where the engine's two functions are.** The Context says
  `check_accepts/2` "is decided and not yet on main" and that neither
  function "is in a published statifier release". Both
  `Statifier.Chart.events/1` and `Statifier.Chart.check_accepts/2` are in
  statifier 2.7.0. The `@doc` of `check_accepts/2` there states the
  membership reading decision 2 relies on: `check_accepts(machine, [n])`
  answers `unreachable: []` when some reachable descriptor matches `n`
  and `[n]` when none does.
- **The two cross-repo records' status.** The Context calls st-ADR-0071
  and sb-ADR-0014 proposed. Both are accepted now, st-ADR-0071 on
  statifier-ex's main and sb-ADR-0014 on statifier_blocks' main.
- **The code half's wait.** The Consequences say the code half waits
  for a published release carrying `check_accepts/2`. That release is
  2.7.0, and the code half has landed as `StatifierRouter.Contracts`,
  whose private `judge/3` calls `Statifier.Chart.check_accepts/2` for a
  receiver that declares nothing and defines no descriptor matching of
  its own.

## Note (2026-09-22, sr-fon): accepted

The status on line 3 reads `accepted`. The flip was made on the
operator's grant of 2026-09-22 to flip proposed records in this
repository, and nothing above this Note changed but that one word. The
Note above it meets the sentences that were overtaken after the record
was written.

**Where the claims were verified.** Every claim this record makes about
this package and its engine dependency was re-read by anchor at
`2d053d513c5ddf38f2faba57d9cfd6412d79db6f`, with statifier 2.7.0 as
`mix.lock` resolves it there:

- The binding's `document` and `event` are required non-empty strings:
  `StatifierRouter.Binding`'s moduledoc table and its `@required` list.
- The reserved name is `StatifierRouter.SendHandler.execution_target/0`.
- `StatifierRouter.Routes.unregistered/2` answers `unregistered` and
  `unchecked`, reports `:typeexpr` and `:targetexpr`, and never reports
  the reserved execution target; `StatifierRouter.Routes.unsupported_types/2`
  composes `Statifier.Send.Types.unsupported_sends/2`.
- The resolver's `resolve/2` callback takes `(scope, document)`, and
  `{:error, :not_published}` appears only in its moduledoc's example
  host (`StatifierRouter.Resolver`).
- A resolver error surfaces as `{:error, {:unresolved_document,
  document, reason}}` and an answer outside the resolver's type raises:
  `StatifierRouter.Delivery`'s private `resolve/3`.
- Nothing under `lib/` produces `dropped: unmatched_event`, so decision
  5's account of what refuses today holds.
- Decisions 1 to 4 and 6 are what `StatifierRouter.Contracts` builds:
  selection on the literal configuration type and the literal reserved
  target in its private `classify/4`; the literal `document` param in
  `literal_document/1` and `literal_param/1`; the three answers of the
  lookup, the three reasons and the raise on any other answer in
  `judge/3`; the four unchecked reasons in `literal_event/1` and
  `literal_document/1`; and the five keys, with both route functions
  composed unchanged, in `check/3`. The surface is the three public
  functions the record names, `undeclared_events/3`,
  `undeclared_binding_events/2` and `check/3`.
- No module under `lib/` adds a `Statifier.Validator` finding, and
  neither `mix.exs` nor `mix.lock` names statifier_blocks.
- The example is proved by the three publish cases in `corpus/cases/`,
  `publish-undeclared-binding-event.json`,
  `publish-undeclared-receiver-event.json` and
  `publish-computed-set-fallback.json`, which the corpus runner answers
  through `StatifierRouter.Contracts.check/3`.

**One behaviour the code has that this record does not decide.** When a
selected send's event and its `document` are both uncheckable, the code
reports the event's reason; `StatifierRouter.Contracts`'s
`t:unchecked/0` typedoc says so. Decision 3 lists the reasons and does
not say which one a send that earns two carries. Accepting this record
does not decide it; the open bead sr-583 carries whether it is pinned by
a test or recorded in a later Note.

The status column for this record in `docs/adr/README.md` still reads
`proposed`. This repository flips that index in a change of its own,
separate from the record's flip, so it lags this file until then.

## Amendment (2026-09-23, sr-77m): a delayed send to the execution target is a finding under `undeclared_events`, with reason `:delay`

Status: proposed

Decision 1 selects an execution-target send by its literal `type` and
its literal `target`, and nothing in this record says what a **delayed**
one means: a `<send>` that writes `delay` or `delayexpr`. Since
ADR-0006's delay Amendment (2026-09-23) no such send is ever delivered,
and this check says nothing about it.

- **What the check does today.** `StatifierRouter.Contracts`'s private
  `classify/4` selects a send on its `type` and `target` alone and never
  reads its `delay` (read at `57b9610`). A delayed send with a literal
  event and a literal `document` is judged against the lookup like any
  other, and one whose event the receiver declares passes with no
  finding.
- **What happens to it at run time.** On the compiled machine a
  `<send>`'s `delay` is `{:static, value}` for `delay`,
  `{:compiled, _, _}` for `delayexpr`, and `nil` when neither is written
  (`Statifier.Machine.Content.Send`'s `t/0`, statifier 2.7.0 as
  `mix.lock` resolves it at `57b9610`). Only `nil` gives an immediate
  send. Any other `delay` either resolves to whole milliseconds, and the
  engine emits a delayed-send effect even for a zero delay (the private
  `build_effect/6` of `Statifier.Machine.Content.Send`'s
  `Statifier.ExecutableContent` implementation), or fails to
  resolve, and the engine discards the send with `error.execution`
  (st-ADR-0036, `docs/adr/0036-send-argument-failure-discards-the-message.md`
  in statifier-ex); a literal `delay` that is not a duration fails there
  with `{:invalid_delay, value}` (`Statifier.Duration.to_ms/1`). A
  delayed effect that names the reserved target is refused with
  `{:error, {:send_refused, :delay}}` before the route registry or the
  timer queue is asked (the first clause of
  `StatifierRouter.SendHandler`'s `enqueue/4`, read at `57b9610`). So a
  selected send with a `delay` or a `delayexpr` never reaches its
  receiver, whatever its value.

### The decision

1. **Which send.** A send decision 1 selects whose `delay` is not `nil`:
   a literal `delay` or a `delayexpr`.
2. **A finding, not an unchecked entry, and a `delayexpr` too.** Its
   run-time result is already known, which is decision 4's reason for
   making an unpublished receiver a finding rather than a gap: the
   handler refuses it, or the engine discards it first. A `delayexpr`
   is reported exactly as a literal `delay` is and is never listed
   unchecked, because every value it can take lands on one of those two
   paths.
3. **Under `undeclared_events`, with reason `:delay`.** `check/3` keeps
   its five keys (decision 6); no sixth is added. Not `unchecked`,
   whose entries are sends whose result cannot be known (decision 3).
   Not `unregistered_routes`, which is `Routes.unregistered/2`'s list
   composed unchanged, never reports the reserved target, and names a
   route a host forgot to register, when here no route is involved.
   `undeclared_events` is the list of execution-target sends whose
   event will not be taken by their receiver, and a delayed one is such
   a send. Its reasons become four: `:undeclared`,
   `:undeclared_by_computed_set`, `:not_published` and `:delay`.
   `undeclared_binding_events` keeps three, because a binding has no
   delay.
4. **The finding's shape.** `%{event, document, location, reason:
   :delay}`, with `location` the `<send>` element's. `event` is the
   literal event when the send writes one and `nil` otherwise; `document`
   is the receiving document when the `document` param is literal by
   decision 1 and `nil` otherwise. Only a `:delay` finding carries
   `nil` in either field, which is the shape `Routes.unregistered/2`'s
   findings already have for a route name it cannot read (`route:
   String.t() | nil` in `StatifierRouter.Routes`'s `t:finding/0`, read at
   `57b9610`).
5. **One entry per send, and the delay first.** A selected send with a
   `delay` gets the `:delay` finding and nothing else: the lookup is not
   called for it, and no `:eventexpr`, `:no_event`, `:document_expr` or
   `:no_document` entry is added for it, because nothing it names is
   delivered.

### The example

The `delivery_round` document of this record's example writes its send
with a two-hour delay:

    <send type="myapp:router" target="execution" event="parcel.delivered" delay="2h">
      <param name="document" expr="'parcel'"/>
      <param name="key" expr="parcel_id"/>
    </send>

`parcel` declares `parcel.delivered`, so decision 2 alone passes it. By
this Amendment `undeclared_events` holds
`%{event: "parcel.delivered", document: "parcel", location: location,
reason: :delay}` for it. Written as `delayexpr="reminder_after"`, it
gives the same finding.

### What this Amendment does not decide

- **Support for a delayed execution-target send.** ADR-0006's delay
  Amendment leaves it to a later record; if that record lands, it
  retires this finding in the same change.
- **A delayed send this check does not select.** One written with
  `typeexpr` or `targetexpr` stays on `Routes.unregistered/2`'s
  unchecked list; a delayed send to a registered route is unchanged.
- **The rest of ADR-0006's envelope.** "What this record does not
  decide" still leaves `key` and `create` to a later record.

The code half is a later change on the same bead, citing this
Amendment: `classify/4` and `judge_send/3`, the `reason` and `finding`
typedocs, the moduledoc's reasons, and the `@doc`s of
`undeclared_events/3` and `check/3`, with tests that pin a literal
`delay`, a `delayexpr`, a delayed send whose event is an expression, and
that the lookup is not called for a delayed send. This Amendment changes
no line above it, and it leaves line 3 as it is.
