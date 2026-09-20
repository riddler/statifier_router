# ADR-0007: The source invoke: an invocation's lifetime is a subscription's lifetime, what `cancel/2` undoes, the cleanup table, durable mode only, and a subscription as its own table

Status: proposed

## Context

Every record before this one answers the same shape of question: an event
arrives from outside, and the router decides which durable execution it
belongs to. A binding declares that, once, for every execution of a
document (ADR-0001), and the address table names the one execution a key
resolves to (ADR-0002). A binding is therefore standing: it applies to an
execution for as long as that execution exists, whatever state it is in.

Some charts want the opposite. A chart that is waiting in one state for
the events of one source - a screen that is open, a window that is
collecting, a job whose progress it is following - wants those events
only during that state, not before it and not after it. SCXML already
has the element for a thing whose life is bounded by a state: spec 6.4's
`<invoke>`, which starts when the state is entered and is cancelled when
the state is left. This record fixes how a chart asks for a bounded
subscription to a source with an `<invoke>`, and which layer owns each
piece of the cleanup that follows.

Facts outside this record that bound the answer:

- **The engine cancels invocations on state exit, itself.**
  `Statifier.Interpreter.ExitEntry`'s `depart/2` is "`exitStates`'s
  per-state exit body: run its onexit blocks, then `cancelInvoke(inv)`
  for each of its live invocations - spec 6.4's 'the cancel operation
  MUST act as if it were the final `<onexit>` handler in the invoking
  state' - then remove it from the configuration", and
  `cancel_invocations_for_state/2` emits "one
  `{:cancel_invoke, %Effect.CancelInvoke{}}` per live invocation of
  `state_index`" (statifier 2.5.0,
  `lib/statifier/interpreter/exit_entry.ex`).
- **The engine cancels no delayed send on state exit.**
  `Statifier.Effect.CancelInvoke`'s own moduledoc draws the line:
  "`Effect.Cancel` is spec 6.3's `<cancel sendid>` - an authored element
  that cancels a *delayed send* [...]. This effect has no `<cancel>`
  element behind it at all: it is the interpreter's own reaction to a
  state exiting while one of its `<invoke>`s is still live, and it has no
  notion of a delayed send to look up" (statifier 2.5.0,
  `lib/statifier/effect/cancel_invoke.ex`). Nothing on the exit path
  names a timer: the only cancellation `depart/2` performs is the
  invocation one above.
- **A live session's delayed-send holds are process references.**
  `Statifier.Session.Timers` is "the pending delayed-send timers, as a
  value", holding `reference()`s, and "resolving [a `sendid`] against
  the pending `SendDelayed` timers is `Statifier.Session`'s job"
  (statifier 2.5.0, `lib/statifier/session/timers.ex` and
  `lib/statifier/effect/cancel.ex`). A durable host runs no Session: it
  receives `{:send_delayed, _}` and `{:cancel, _}` as effects at the
  executor seam, one call per effect
  (`StatifierPersistence.Executor`'s `c:execute/2`,
  statifier_persistence 0.12.0).
- **The router hosts through two doors, and already carries the host's
  type snapshots onto both.** `StatifierRouter.Delivery` calls
  `StatifierPersistence.Executions.create/4` and `.step/5` with the
  configuration's `:executor` and its `:persistence_options`, "the
  per-call snapshot options both doors carry, `:routes`, `:invoke_types`
  and `:send_types`", which "reach a `step/5` beside the event and a
  `create/4` inside its `initialize:`"
  (`lib/statifier_router/delivery.ex`). Registering the invoke type a
  source invoke is spelled with therefore needs no new seam: the host
  passes it where it already passes its send types. Answering an
  invocation is what the package has no door for. `StatifierPersistence.Driver.done_invocation/5`
  "[a]nswers a `:pending` invocation with `donedata` and drives the
  execution to quiescence", deciding a discard "from the loaded position
  inside the execution's serialization strategy"
  (statifier_persistence 0.12.0,
  `lib/statifier_persistence/driver.ex`): a drive of its own on the
  execution it answers, taking that execution's serialization for
  itself, rather than a statement inside the transaction a delivery is
  already holding (ADR-0003, section 1). `.failed_invocation/5` is
  documented there as "`done_invocation/5`'s failing counterpart".
- **`mode` cannot be spelled on a binding.** ADR-0001, section 6:
  "`mode`, `batch` and `window` are **reserved**: a binding carrying any
  of them is refused at construction, and the refusal names the reserved
  key it found." `StatifierRouter.Binding` holds
  `@reserved [:mode, :batch, :window]` and refuses both the atom and the
  string spelling (`lib/statifier_router/binding.ex`).
- **An `always_new` delivery writes no address row.** ADR-0002, section
  7, and `Delivery`'s `:always_new` branch: it "neither reads nor writes
  an address row [...]. It mints an execution id, asks the resolver for
  the chart and calls `create/4` under that id, for every delivery; the
  minted id is the only handle on the execution"
  (`lib/statifier_router/delivery.ex`).

## Decision

### 1. The spelling, and what the invoke's params name

A chart asks for a bounded subscription with

```xml
<invoke type="myapp:source">
  <param name="binding" expr="'clicks_to_join'"/>
</invoke>
```

- the invoke's `type` is the host-registered invoke type the host's
handler answers to (the host chooses the string; `myapp:source` is this
record's example, and the host registers it in the
`t:Statifier.Invoke.Types.t/0` snapshot it stamps), and its params name
**the binding id and nothing else**. The key is not a param: it is the
execution's own address key, which the router reads for itself (section
6), because an execution that could name its own key could name another
execution's. A source invoke carries no `src` and no `<content>`.
`Statifier.Effect.Invoke` carries the `invoke_id`, the `type` and the
resolved `params` (statifier 2.5.0, `lib/statifier/effect/invoke.ex`),
which is everything the host's handler needs in order to subscribe.

### 2. The invocation's lifetime is the subscription's

Entering the state subscribes and leaving it unsubscribes: the host's
invoke handler turns the `{:invoke, _}` effect into a subscription of
this execution to that binding, and the engine's own
`{:cancel_invoke, %Effect.CancelInvoke{}}` on state exit - which
`depart/2` emits per live invocation, as the Context quotes - into
`StatifierRouter.cancel/2` for the same `(binding, execution)` pair. The
chart writes no cleanup for it. Both effects arrive at the executor seam
the router already hands `create/4` and `step/5`, so one handler serves
the start and the cancel.

### 3. What `cancel/2` undoes

`StatifierRouter.cancel/2` undoes the subscription row that the matching
subscribe created, and anything that subscription itself scheduled, and
nothing else. It does not touch the execution, its address row, its
input log, its ledger rows, any delayed send the chart armed, or any
other binding's subscription for the same execution. An execution that
ends its life with subscriptions still live is not this function's
business either: `cancel/2` is called for one cancelled invocation, not
for an execution's end.

### 4. The cleanup table

| What was armed | Cancelled on state exit by | Owner of the cleanup |
|---|---|---|
| A source invocation (`<invoke type="myapp:source">`) | the engine, `for inv in s.invoke: cancelInvoke(inv)` in `depart/2` | the host's invoke handler, turning `{:cancel_invoke, _}` into `StatifierRouter.cancel/2` |
| A delayed send the chart armed (`<send>` with `delay`) | nothing - the engine cancels no delayed send on exit | the chart, which owes its own `<cancel sendid>` in `<onexit>`; an authoring layer may emit that `<cancel>` on the author's behalf |
| A delayed send of a registered send type, on a durable host | nothing | the send handler at the executor seam, which holds the send and honours the matching `{:cancel, %Effect.Cancel{}}` effect |

The second and third rows differ only in who holds the pending send, and
that is the whole point of separating them. In a live session the hold is
a process reference in `Statifier.Session.Timers`, which no restart
survives; a durable host runs no session, receives `{:send_delayed, _}`
and `{:cancel, _}` as ordinary effects, and therefore owns both the hold
and the cancel. A chart that arms a timer and leaves the state without a
`<cancel>` has a timer that will still fire, on either host. The engine's
exit path is not a general cleanup hook, and this record does not make it
one.

### 5. Durable mode only

The source invoke is specified for durable executions only. A
subscription is a row (section 6), so it survives a restart with no
further mechanism: the host's handler re-reads it, and an event arriving
after a restart routes exactly as one arriving before it. A live,
in-memory variant is not specified here and cannot be asked for: `mode`
is one of ADR-0001 section 6's reserved binding keys, refused by name at
construction, so `mode: live` is a refusal today and stays one until a
later record opens the key.

### 6. What a subscription is in this package's tables

A subscription is a **new table**, not an address row with a flag. The
code bead that builds the invoke handler and
`StatifierRouter.cancel/2` owns that migration, alone, as the next
router migration version; no other bead adds one.

The address table cannot carry it. Its columns are `scope`, `document`,
`key`, `execution_id` and `inserted_at`, every one `null: false`, with
only `terminal_seen_at` nullable, and it is unique on
`(scope, document, key)` (`lib/statifier_router/migrations/v01.ex`).
Three things follow. One execution subscribes to as many bindings as its
states invoke, and a single row on a triple has one flag to give, not N.
An execution created by an `always_new` binding has no address row at
all - that delivery "neither reads nor writes an address row" - so there
is nothing to flag. And an address row outlives its execution on
purpose, kept "for the longest dedupe horizon of any enabled binding
naming its document" (ADR-0002, section 5), where a subscription ends when its
invocation is cancelled; one row cannot have both lifetimes.

The subscription row therefore records, at least, the binding id, the
execution id, the scope, the key the subscription reads events under,
and the invocation it belongs to, so that `cancel/2` deletes exactly the
row its subscribe created and two invocations of the same binding in one
execution do not cancel each other. The key is the execution's own
address key, resolved once at subscribe time **by execution id alone**.
No scope and no delivery is in hand there: the executor seam's context is
`%{execution_id: String.t(), content_hash: String.t()}`
(`StatifierPersistence.Executor`, statifier_persistence 0.12.0) and the
invoke effect carries its id, its type and its params, which name the
binding alone. The execution id is enough, because the V01
`<table>_execution_id_index` on `execution_id` finds the row without a
scan and finds at most one: the router mints a fresh opaque execution id
at every create (ADR-0002, section 3), so no id is ever written under two
addresses. The row it finds carries the scope and the key. An execution
with no such row - an
`always_new` create - has no key to subscribe under, and its source
invoke is refused rather than subscribed under an invented key, the same
rule ADR-0001 section 3 already applies to a binding whose `key` produces
nothing. The code bead's tests enumerate the refusals and the column
list; this record fixes that the table is new, what it must distinguish,
and where the key comes from.

### The open trigger this record does not design

A state that exists only to wait for one answer is an `<invoke>`, not
something a chart gets back from an outbound send. The router-hosted
**invoke answer path** - a host handler that starts
work on invoke and answers this same execution when the work completes -
is **unbuilt**, and this record does not design it. The router hosts
through `create/4` and `step/5`, handing them an executor and the host's
snapshot options, which is enough to register an invoke type and not
enough to answer one; the doors that
answer an invocation, `Driver.done_invocation/5` and
`.failed_invocation/5`, drive the **answered** execution - the invoking
one, which is waiting on the answer - under that execution's own
serialization, a drive of its own and outside the caller's-transaction
discipline ADR-0003 fixes for a delivery. The source invoke specified
above needs none of that: it subscribes and unsubscribes, and every event
it wants arrives through the ordinary binding path. Opening the answer
path is a later record's, and it is named here so a chart author reading
this one knows which half of `<invoke>` this package supports.

## Consequences

- A chart can scope a subscription to a state without the host writing
  any lifecycle code: the engine's own exit cancellation is the only
  trigger, and the host's handler is two calls, subscribe and
  `cancel/2`.
- The cleanup table has no fourth row and no catch-all. Anything a chart
  arms that is not an invocation is the chart's to disarm, and a chart
  that forgets is not rescued by the engine or by this package. An
  authoring layer that emits `<onexit><cancel/></onexit>` for its users
  is doing what the chart owes, not what the engine does.
- A durable host cannot reuse a live session's timer behaviour by
  accident, because it has none to reuse: the hold and the cancel both
  arrive as effects, and a handler that ignores `{:cancel, _}` fires a
  send its chart cancelled.
- The package gains a table, and with it a second migration version. A
  host that has already run V01 writes its next migration with
  **`from: 2`**. `StatifierRouter.Migrations.up/1` walks `from..version`
  **inclusive of `from`**, and `from:` defaults to V01, so the default
  call on such a host re-runs V01's `CREATE TABLE` against tables it
  already has: `from:` names the first version the host has **not** run,
  never the newest it has (`lib/statifier_router/migrations.ex`, whose
  moduledoc says the same). A host installing the package for the first
  time takes the default and gets both versions in one call.
- Subscriptions are per binding, execution and invocation, so fan-out
  works the way bindings already do: two states invoking two bindings
  subscribe twice, independently, and one exit cancels one of them.
- `always_new` and the source invoke do not compose. A binding that
  creates a new execution per event addresses none of them, so an
  execution of such a document cannot say which key it would subscribe
  under. That is visible as a refusal on the invocation rather than as a
  silent subscription, and a host that wants both needs a keyed binding.
- `mode: live` stays unavailable, and a later record that opens it starts
  from a name no configuration has been able to use.
- This record leaves to later records: the router-hosted invoke answer
  path; whether a subscription ever ends for a reason other than its
  invocation's cancellation; and any batching or windowing of what a
  subscription delivers, which ADR-0001's other two reserved keys hold
  open.
