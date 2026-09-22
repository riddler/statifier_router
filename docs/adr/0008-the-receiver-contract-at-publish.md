# ADR-0008: The receiver contract at publish: an execution-target send's literal event and a binding's event are checked against the receiving document's declaration through a host-supplied lookup, a receiver that declares nothing is judged by the engine's computed vocabulary, what cannot be read from a literal is reported unchecked, an unpublished receiver is a finding of its own, and the package ships pure functions the host's publish step calls

Status: proposed

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
  of `Statifier.Machine.Param`. A `%Param{}`'s `expr` is always the
  compiled form, `{:compiled, %Predicator.Compiled{}, source}`, whether
  the author wrote `expr` or `location` (its `kind` says which). An author
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
  `StatifierRouter.SendHandler.execution_target/0`. That is exactly the
  set `StatifierRouter.SendHandler` will hand to ADR-0006's delivery at
  run time, the same reasoning `Routes.unregistered/2`'s `@doc` gives for
  judging only the configuration's own type. Such a send is judged when
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
means a publish check has a bug: this one, or the receiver's own check
of its declaration (st-ADR-0071, decision 3). A drop of a name this
check reported unchecked is the gap decision 3 already named.

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
