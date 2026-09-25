# The routing corpus

Cases that drive the router end to end: bindings, a chart, the routes the
case registers, a script of deliveries and clock advances, and what the
ledger, the routes, the execution and its datamodel hold at the end. Each
case is a JSON document with no term of any programming language in it, so
a runner in another language can execute the same files. The runner in
this repository is `test/support/corpus_runner.ex`, and
`test/corpus_test.exs` runs every case under `mix test`, against the real
delivery and a real Postgres database. A publish case, below, drives no
delivery: it holds a chart, the host's declarations and what the receiver
contract at publish reports over them.

The corpus is a test fixture. It is not part of the published package.

## Layout

    corpus/
      charts/<document>.scxml   the chart a document starts its executions on
      cases/<id>.json           one case per file, named for its id

## The chart: the impression / click join

`charts/impression_click_join.scxml` is the left outer join of ad
impressions and their clicks, one execution per `impression_id`:

- The first event decides the path, and the impression's id is kept in
  the datamodel as the join key. An impression waits in `awaiting_click`
  for 24 hours; a click waits in `awaiting_impression` for 1 hour.
- A click on a waiting impression, or an impression for a waiting click,
  reaches `joined`, which cancels both timers. A window that closes
  reaches `expired`. An orphan timer that fires records an orphan click.
- Each path then holds `closed`, a 1 hour grace period, in which a late
  click is appended to `late_clicks` and a further impression is absorbed.
  When the grace period ends, the execution finishes in the final state
  `done`.

The result of the join leaves the chart as a send rather than staying in
the datamodel. A completed join reaches the route `joined_records`; a
click no impression joined - a click whose hour ran out, an impression
whose window closed, and a click that arrives once the join has closed -
reaches `dead_letter`. Each send names the host's send type in `type` and
the route name in `target`, which is how ADR-0005 spells an outbound send,
and each carries the join key as a `<param>`. What the execution still
holds is `late_clicks`, the data of each click that arrived during the
grace period, which is state rather than a result it hands out.

A timer is a `<send>` with a `delay` and no `target`, and every timer a
chart cancels is cancelled by its send id. A `target` therefore appears
only on a routed send, and names a route a case registers rather than a
host scheme; `test/corpus_test.exs` checks both halves of that against
every chart. The one other `target` a chart may write is the reserved
execution target, `execution`, which names another execution rather
than a route (ADR-0006, section 1) and which no case can register as a
route. statifier hands timers to the host as effects; see "The runner
plays the host" below.

## The charts: a parcel and its depot

`charts/parcel.scxml` is a parcel scanned from depot to doorstep, one
execution per parcel id: it waits in `at_depot` until `parcel.scanned`,
is then `in_transit`, and ends in `delivered` on `parcel.delivered` or
in `returned` on `parcel.returned`. Those three names are its computed
vocabulary.

`charts/depot.scxml` is the depot's handling of a parcel a courier
brings back. On `courier.nobody_home` it sends `parcel.returned` to the
parcel's own execution: the host's send type in `type`, the reserved
execution target in `target`, and the receiving document and the
parcel's key as `<param>`s, which is how ADR-0006 spells a send from one
execution to another.

The publish cases use these two charts only.

## A case

```json
{
  "id": "impression-then-click",
  "description": "What the case shows, in one sentence.",
  "document": "impression_click_join",
  "scope": "7c1e",
  "routes": ["joined_records", "dead_letter"],
  "bindings": [
    {
      "id": "impressions_to_join",
      "source": "ad_events",
      "match": "event.kind == 'impression'",
      "key": "event.impression_id",
      "document": "impression_click_join",
      "event": "impression",
      "data": ["impression_id", "shown_at", "placement"]
    }
  ],
  "script": [
    {"deliver": {"source": "ad_events", "message_id": "ad_events/3/1042", "data": {"kind": "impression", "impression_id": "imp_7f3a"}}},
    {"advance": "PT2H"}
  ],
  "expected": {
    "ledger": [
      {"binding": "impressions_to_join", "message_id": "ad_events/3/1042", "outcome": "created_and_delivered", "key": "imp_7f3a"}
    ],
    "status": "active",
    "configuration": ["awaiting_click"],
    "timers": ["window.closed"],
    "sends": [],
    "datamodel": {"late_clicks": []}
  }
}
```

| Field | Holds |
|---|---|
| `id` | the case's name, the same as its file name without `.json` |
| `description` | one sentence on what the case shows |
| `document` | the document every binding in the case addresses; its chart is `charts/<document>.scxml`. In a publish case, the document whose chart is checked |
| `scope` | the host scope every delivery routes under |
| `routes` | the route names the case registers, each served by a recording adapter that hands nothing anywhere; a chart that sends to a route absent from this list is refused rather than delivered |
| `bindings` | the bindings, as ADR-0001 fixes them: `match` and `key` are predicator source strings, and a binding's enumerated values (`create`, `order`) are strings |
| `script` | the steps, in order (below); a publish case has none |
| `declarations` | optional, publish cases only: the host's declarations, an object from a document id to the list of event names it declares (see "A publish case") |
| `expected` | what the case checks at the end (below); a key left out is not checked, with the one exception `sends` names |

A step is one of:

- `{"deliver": {"source": ..., "message_id": ..., "data": {...}}}` - one
  event, routed through every binding for its source. `data` is the
  normalized event the bindings' programs read as `event`.
- `{"advance": "<ISO 8601 duration>"}` - moves the clock forward, firing
  every timer that falls due on the way.
- `{"reap": "addresses"}` - one run of the address reaper at the case's
  current clock. The reaper stamps a terminal address row the first time
  it reads it and deletes it once that row's horizon has passed, so a case
  reaps twice around an advance to see a row gone.

`expected` may hold:

| Key | Compared with |
|---|---|
| `ledger` | the routing ledger's rows for the case's bindings, oldest first, each as `binding`, `message_id`, `outcome` and `key`; `outcome` is spelled as ADR-0004 spells it (`delivered`, `created_and_delivered`, `duplicate`, `key_refused`, `dropped: no_execution`, `dropped: finished`) |
| `status` | the execution's status: `active`, `completed`, `failed` or `cancelled` |
| `configuration` | the execution's active leaf states, sorted; a finished execution has none |
| `timers` | the event names of the timers still pending, sorted |
| `sends` | every send a route was handed, in the order the routes were handed them, each as `route` and `event` (the event's `name` and its resolved `data`); the match is exact, so a case states `[]` to assert that no send was handed anywhere |
| `datamodel` | the named datamodel entries of the execution |
| `contracts` | what the receiver contract at publish reports; a case that states it is a publish case (see "A publish case") |

`sends` is the one member a case may not leave out once it registers
routes: the runner raises on a case with `routes` and no `expected.sends`
rather than running it, because a member left out is compared against
nothing and the case would pass whatever the chart sent.

A case addresses exactly one execution: its scope and document name one
address. Execution ids are minted at delivery and appear nowhere in a
case, and an address row the reaper deletes does not take the execution
the case compares with it.

## A publish case

A case whose `expected` holds `contracts` is a publish case. It runs no
script and addresses no execution; the runner raises on a publish case
that carries steps, because a step it would not run is one the case
could not check. The runner builds the case's configuration from its
`scope`, `routes` and `bindings`, takes the chart `document` names, and
compares `contracts` with `StatifierRouter.Contracts.check/3` over the
two, under the lookup ADR-0008 decision 2 describes, built from
`declarations`:

- a document `declarations` names declares exactly those event names;
- a document it leaves out whose chart is under `charts/` declares
  nothing, and is judged by that chart's computed vocabulary through
  `Statifier.Chart.check_accepts/2`;
- any other document is not published.

`contracts` holds the report's five lists, each compared exactly:
`unsupported_types`, `unregistered_routes`, `unchecked`,
`undeclared_events` and `undeclared_binding_events`. A finding is an
object of strings: `event`, `document`, `reason` (`undeclared`,
`undeclared_by_computed_set` or `not_published`, or `delay` for a `<send>`
that writes `delay` or `delayexpr`), and either `binding_id`
for a binding or `location` for a `<send>`, the element's start as
`line` and `column`.
An `unregistered_routes` entry is an object of `route`, `location` and
`reason`: `unregistered` when the `<send>` names no registered route, or
`no_timer_queue` for a literal `delay` to a registered route on a
configuration with no timer queue (ADR-0008, the 2026-09-24 Amendment).

The publish cases prove one refusal: an event a sender or a binding
names that the receiving document does not accept is refused at publish,
before any chart or configuration ships, where at run time the event
would be delivered and the receiver would take no transition (ADR-0008).
`publish-undeclared-receiver-event` proves it for a send to the execution
target, `publish-undeclared-binding-event` for a binding, and
`publish-computed-set-fallback` proves that a receiver which declares
nothing is judged by its chart's computed vocabulary and accepts a name
its chart takes. This suite shares no schema with statifier's own corpus
or with the reference host's cases: each suite states its cases in its
own shape.

## A case is language-neutral

A case holds JSON strings, numbers, booleans, null, lists and objects, and
nothing that belongs to one programming language: no string that spells a
language's symbol or atom, no map literal, no module name. Programs are
predicator source, durations are ISO 8601, timestamps in event data are
RFC 3339 strings, and outcomes are the words of ADR-0004. `test/corpus_test.exs`
checks every case file for this.

## The runner plays the host

statifier leaves timers to the host: a delayed `<send>` reaches the host as
a delayed-send effect and a `<cancel>` as a cancel effect. A runner records
both and keeps its own clock, which moves only on an `advance` step. On an
advance it fires, in the order they fall due, the recorded sends whose delay
has elapsed, each by stepping its event into its execution through
statifier_persistence's `Executions.step/5` with the chart the router's
chart resolver answers for that execution. A send is fired at the time it
fell due, so a send it schedules is timed from there. A cancel removes the
execution's recorded sends that carry its send id. The router itself keeps
no timer.

statifier leaves sinks to the host in the same way. A runner registers one
adapter per name in the case's `routes`, hands every effect to this
package's own send handler, and records what each adapter was handed. An
adapter records and answers; it hands nothing anywhere, and it returns no
data, which is what ADR-0005 makes a route.

## The cases

| Case | Shows |
|---|---|
| `impression-then-click` | an impression, then its click within the window: joined, handed to `joined_records`, the window timer cancelled, the grace period held, then finished |
| `click-then-impression` | a click before its impression, and the impression within the hour: joined, handed to `joined_records`, the orphan timer cancelled, the grace period pending |
| `impression-then-expiry` | an impression with no click: past 24 hours the window closes and the closed window reaches `dead_letter`, the grace period pending |
| `click-then-orphan-timeout` | a click with no impression: past 1 hour the orphan reaches `dead_letter`, and past the grace period the execution finishes |
| `grace-click-after-expiry` | a click in the grace period that follows a closed window: the window and then the late click each reach `dead_letter`, and the click is kept in `late_clicks` as well |
| `redelivered-impression` | the impression's message delivered again in every state the execution rests in once it holds the impression (`awaiting_click`, `closed`, and after it finished), each a duplicate; a new message for the same impression during the grace period, delivered and absorbed |
| `two-clicks-for-one-impression` | an impression and two clicks: the first joins, the second arrives in the grace period, reaches `dead_letter` and is kept in `late_clicks` |
| `publish-undeclared-receiver-event` | the depot's send of `parcel.returned` against a `parcel` that declares only `parcel.scanned` and `parcel.delivered`: refused as `undeclared`, though the parcel's chart would take the name |
| `publish-computed-set-fallback` | the same send against a `parcel` that declares nothing: judged by the parcel chart's computed vocabulary through `Statifier.Chart.check_accepts/2`, which holds `parcel.returned`, and accepted |
| `publish-undeclared-binding-event` | a binding that routes the depot feed's missing-parcel report into `parcel` as `parcel.lost`, against the same two declared names: refused as `undeclared` |
| `reaped-address-drop` | a click for an impression whose execution finished and whose address row the reaper then deleted: a drop on the ledger, and nothing handed to a route |
