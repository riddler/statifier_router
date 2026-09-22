# The routing corpus

Cases that drive the router end to end: bindings, a chart, the routes the
case registers, a script of deliveries and clock advances, and what the
ledger, the routes, the execution and its datamodel hold at the end. Each
case is a JSON document with no term of any programming language in it, so
a runner in another language can execute the same files. The runner in
this repository is `test/support/corpus_runner.ex`, and
`test/corpus_test.exs` runs every case under `mix test`, against the real
delivery and a real Postgres database.

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
every chart. statifier hands timers to the host as effects; see "The
runner plays the host" below.

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
| `document` | the document every binding in the case addresses; its chart is `charts/<document>.scxml` |
| `scope` | the host scope every delivery routes under |
| `routes` | the route names the case registers, each served by a recording adapter that hands nothing anywhere; a chart that sends to a route absent from this list is refused rather than delivered |
| `bindings` | the bindings, as ADR-0001 fixes them: `match` and `key` are predicator source strings, and a binding's enumerated values (`create`, `order`) are strings |
| `script` | the steps, in order (below) |
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

`sends` is the one member a case may not leave out once it registers
routes: the runner raises on a case with `routes` and no `expected.sends`
rather than running it, because a member left out is compared against
nothing and the case would pass whatever the chart sent.

A case addresses exactly one execution: its scope and document name one
address. Execution ids are minted at delivery and appear nowhere in a
case, and an address row the reaper deletes does not take the execution
the case compares with it.

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
| `reaped-address-drop` | a click for an impression whose execution finished and whose address row the reaper then deleted: a drop on the ledger, and nothing handed to a route |
