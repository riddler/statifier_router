# How to fit the router into an engine of your own

Some hosts already run statifier_persistence under an engine of their own: a
stepper that stamps its own snapshot options on every create and every step,
keeps rows of its own beside each execution, wraps its work in a tenancy
context, and runs Oban. This guide puts the router's options for such a host
into one configuration, one step per option, and answers what such a host
meets first. It starts from that engine and a router configuration that
already delivers.

The example routes a parcel's scans from depot to doorstep. Where the steps
end up:

```elixir
{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    store: store,
    executor: &MyApp.ParcelStepper.execute/2,
    resolver: MyApp.PublishedCharts,
    chart_resolver: &MyApp.PublishedCharts.chart/1,
    bindings_resolver: MyApp.DepotBindings,
    on_create: MyApp.ParcelStepper,
    on_step: MyApp.ParcelStepper,
    execution_id: MyApp.ParcelRouteIds,
    send_type: "myapp:router",
    send_handlers: %{"myapp:courier" => MyApp.Courier},
    route_adapters: %{"doorstep_photos" => {MyApp.OutboxRoute, %{queue: "photos"}}},
    timer_queue: {MyApp.ObanTimerQueue, %{}}
  )
```

`MyApp.Router.config/0` below is the host's own: it returns this
configuration. `:bindings_resolver` is in
[How to bind events from several sources to one execution](how-to-bind-events-to-an-execution.md),
and a host column placed first on every table is in
[How to fit the router's tables to a host](how-to-fit-the-router-tables-to-a-host.md).

## Step 1. Stand in for the create and step calls

A host whose own engine wraps statifier_persistence's two doors can hand the
configuration a stand-in for each. The delivery calls it where it would have
called persistence, with the same arguments, inside the same transaction and
savepoint, and reads its answer as it reads persistence's:

| Option | Stands in for | Takes | Answers |
|---|---|---|---|
| `:on_create` | `StatifierPersistence.Executions.create/4` | a module exporting `create/4`, or an arity-4 fun | `{:ok, execution, state}` or `{:error, reason}` |
| `:on_step` | `StatifierPersistence.Executions.step/5` | a module exporting `step/5`, or an arity-5 fun | `{:ok, execution, state}`, `{:discarded, execution}` or `{:error, reason}` |

With neither set, the delivery calls statifier_persistence itself.
`StatifierRouter.Config`'s documentation says what each receives and what an
error from it rolls back. `MyApp.ParcelStepper` in Step 4 is one module that
serves as both.

A host that wraps every step in a tenancy context of its own (process state
that its repo and its rows read) can set that context in the hook's body. It
then covers the create or the step and what they write through the
configuration's repo, and nothing else the delivery does. The delivery's
transaction on the configuration's repo and its savepoint are open before
either hook is called (`StatifierRouter.Delivery.deliver/4`), and these run in
the router's own context, outside the hook's body:

- the dedupe claim (`StatifierRouter.Dedupe.claim/4`);
- the address row's read, and its insert under `create: :if_absent`, with the
  `:execution_id` call that mints the new id;
- the read of an existing execution's status
  (`StatifierPersistence.Storage.fetch_execution/2`);
- the `:resolver` and `:chart_resolver` calls;
- the `:on_complete` route's delivery of a finished execution's donedata;
- the update that stamps the address row's `terminal_seen_at` once its
  execution has finished;
- the ledger row.

`StatifierRouter.route/3` also asks the `:bindings_resolver` for the bindings
and writes a `key_refused` ledger row with no delivery transaction open at
all. So a context held in the process reaches the create and the step only; a
transaction-local database setting made inside the hook reaches the writes
that come after it in the same transaction but never the claim or the address
row before it; and a session-level setting outlives the delivery on the
pooled connection.

Two existing seams reach further. The configuration's `:delivery` option
names a module whose `deliver/4` can set the context and then call
`StatifierRouter.Delivery.deliver/4`, which wraps one binding's delivery
whole, claim to ledger row. And a host that calls `StatifierRouter.route/3` or
`StatifierRouter.Webhook.handle/3` itself can wrap the call in its own
transaction on the configuration's repo: the delivery's transaction nests into
it. Neither reaches every door. `StatifierRouter.Broadway` calls `route/3`
itself, so a pipeline has no host transaction around it, and its partitioner
asks the `:bindings_resolver` too; the `key_refused` row is written by
`route/3`, outside the `:delivery` module; and a send to an execution target
is delivered by `StatifierRouter.Delivery.deliver_event/4` inside the sending
step, never through the `:delivery` module, whichever scope the target is in.
The `:around_delivery` option in Step 2 is the seam that reaches every door
the router drives itself, with one carve-out: a send's delivery to an
execution target has no door of its own by default, so where no other door's
work encloses it nothing wraps it, and only with `wrap_target: true` beside
the wrapper is it wrapped there, under the door `:target`.

## Step 2. Wrap a whole delivery

The configuration's `:around_delivery` option is the one seam that wraps a
whole delivery: every read and write of it, on the doors the router drives
itself. It is a module exporting `around_delivery/3`, or an arity-3 fun,
handed `(scope, door, work)`; it calls `work` exactly once and answers what
`work` answered. Left out, nothing is called and the router issues the same
statements it did before the option existed.

```elixir
around_delivery = fn scope, _door, work ->
  MyApp.Tenancy.put(scope)

  try do
    work.()
  after
    MyApp.Tenancy.delete()
  end
end

{:ok, config} = StatifierRouter.Config.new(base_options ++ [around_delivery: around_delivery])
```

| Door | Called by | What `work` covers |
|---|---|---|
| `:route` | `StatifierRouter.route/3`, so `StatifierRouter.Webhook.handle/3` and each message `StatifierRouter.Broadway` handles | the bindings read, every `key_refused` row and every binding's delivery |
| `:partition` | `StatifierRouter.Broadway`'s partitioner, in the producer's process | the bindings read for one message |
| `:basichttp` | `StatifierRouter.BasicHTTP.Front.handle/3` | the delivery; the token is resolved before the call, outside it |
| `:target` | `StatifierRouter.SendHandler`, only with `wrap_target: true`, for a send to an execution target no other door's work encloses | the send's delivery, or its `send_refused` row; the sender's address row, whose scope the wrapper is handed, is read before the call, outside it |

A send to an execution target has no door of its own by default. At the
executor seam it runs inside the sending execution's step, so the `:route` or
`:basichttp` call around that step's delivery already encloses it. On the
send-processor shape, and from a step the router did not drive - a delayed
event a timer job steps in, a step you make yourself - nothing of the
router's encloses it. Either wrap the call that performs the send, or the
step, yourself, or opt in with `wrap_target: true` beside the wrapper:

```elixir
{:ok, config} =
  StatifierRouter.Config.new(
    base_options ++ [around_delivery: around_delivery, wrap_target: true]
  )
```

With it, the target's delivery runs inside one call of the wrapper under the
door `:target`, handed the sender's scope, on exactly those two shapes: a
target delivery inside a step a door drove is wrapped once, by that door. A
step you wrap in your own context at your own call is not one the router can
see, so there the wrapper is called again under `:target`, inside your
context, and must allow that. At the executor seam the work runs inside the
sending step's transaction: run it in the calling process, and know that a
rollback from a transaction the wrapper opens there takes the sending step
down too. `:wrap_target` is a boolean and is refused without
`:around_delivery`; left out, or `false`, nothing changes.

A call your own code makes to `StatifierRouter.Delivery`, `subscribe/3`,
`cancel/2`, the location rotation or a reaper is yours to wrap at the call.

A context held in the process reaches every statement `work` runs. A
transaction-local database setting reaches them only when the wrapper opens a
transaction on the configuration's repo before calling `work`, and then every
delivery of one `route/3` call commits, or rolls back, together. The
partitioner's read runs in no transaction, so there only the process context
reaches it. `StatifierRouter.Config` documents the option, and ADR-0003's
Amendment of 2026-10-02 records the decision, and its Amendment of 2026-10-04
the `:wrap_target` opt-in.

Check it by routing one event with a wrapper that records each door it is
handed: one `:route` call per `route/3` call.

## Step 3. Mint the execution id

By default every execution the router creates gets a UXID with the prefix
`ex`. A host that names its executions itself hands the configuration an
`:execution_id`: a module exporting `execution_id/3`, or an arity-3 fun,
taking `(scope, document, key)` and answering a non-empty string:

```elixir
defmodule MyApp.ParcelRouteIds do
  def execution_id(_scope, _document, _key) do
    "route_" <> MyApp.Ids.generate()
  end
end

{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    # ...the store, executor, resolver and chart resolver as before
    execution_id: MyApp.ParcelRouteIds
  )
```

The delivery calls it each time it is about to create an execution, and its
answer is the id on the address row, the id statifier_persistence creates the
execution under, and the id on the ledger. A duplicate delivery, and a
delivery to an address that already has an execution, never call it. Any
answer that is not a non-empty string raises `ArgumentError`. The id must be
new: an id statifier_persistence already holds is refused with
`{:error, :execution_exists}` and the delivery rolls back, so a callback that
derives the id from the address alone fails the second time that address is
filled. Under `:if_absent` a delivery that loses the race for an address row
discards the id it minted, so not every answer ends up naming an execution.

## Step 4. Declare the send types the host serves

`:send_type` is the one type string the router's handler answers to, and
`:send_handlers` maps each send type the host serves itself to the module that
processes it - here a courier processor beside the router's handler.
`StatifierRouter.Config.new/1` builds one `send_types:` snapshot from both, as
`Statifier.Send.Types.from_send_types(%{"myapp:router" =>
StatifierRouter.SendHandler, "myapp:courier" => MyApp.Courier})`, and puts it
into `:persistence_options`. The delivery hands those options to `:on_create`
inside `initialize:` and to `:on_step` beside the event, so the hooks stamp no
snapshot of their own:

```elixir
defmodule MyApp.ParcelStepper do
  alias StatifierPersistence.Executions

  def create(store, execution_id, machine, opts),
    do: Executions.create(store, execution_id, machine, opts)

  def step(store, execution_id, machine, event, opts) do
    with {:ok, execution, state} <- Executions.step(store, execution_id, machine, event, opts) do
      # The host's own row, inside the delivery's transaction.
      MyApp.ParcelLog.record!(execution, event)
      {:ok, execution, state}
    end
  end

  # Each handler ignores the effects that are not its own.
  def execute(effect, context) do
    with :ok <- StatifierRouter.SendHandler.handle_effect(MyApp.Router.config(), effect, context) do
      MyApp.Courier.handle_effect(effect, context)
    end
  end
end
```

The publish-time checks read the same snapshot:
`StatifierRouter.Routes.unsupported_types/2`, and so the `:unsupported_types`
of `StatifierRouter.Contracts.check/3`, judges a chart against the set every
delivery carries, so a `<send type="myapp:courier">` is supported there and a
type in neither key is reported. Left out, `:send_handlers` changes nothing:
the snapshot is built from `:send_type` alone, and a
`<send type="myapp:courier">` is reported unsupported.

A `:send_handlers` entry under the router's own type is refused with
`{:error, {:declared_send_types, "myapp:router"}}`, and so is a configuration
that gives `:send_type` and also gives `:persistence_options` a `:send_types`
of its own. A map that is not one of non-empty type strings to modules, or
that names a built-in spelling such as `"scxml"`, is refused with
`{:error, {:invalid_value, :send_handlers, value}}`. A host whose hooks stamp
a snapshot of their own over the router's keeps working, but its publish
check still reads only the configuration's.

## Step 5. Call `put_config/1` only where a live session sends

At the executor seam it is not called: `StatifierRouter.SendHandler.handle_effect/3`
is handed the configuration by the host's executor, as `execute/2` above
does, and a host whose executions are all stepped behind the executor seam
never calls `put_config/1`.

`StatifierRouter.SendHandler.put_config/1` is for a live `Statifier.Session`
that registers `StatifierRouter.SendHandler` under the router's type. The
session's `perform/2` is handed no configuration and reads it from the
process it runs in, which is the session's own, so the host calls
`put_config/1` in that process before a send is performed there. In a process
that holds none, `perform/2` answers
`{:error, {:no_config, StatifierRouter.SendHandler}}`, which says nothing
about the send and is not reported to the chart; any other `{:error, reason}`
from `perform/2` the host reports with `Statifier.Session.failed_send/3`. The
session's sends resolve their routes in the scope the configuration's
`:processor_scope` names.

## Step 6. Give delayed sends a timer queue over the host's Oban

A `<send>` of the router's type with a `delay` is recorded on the
`:timer_queue`, a module implementing `StatifierRouter.TimerQueue`. Over an
Oban the host already runs, the queue needs:

- **The router's repo.** At the executor seam `schedule/2` and `cancel/3` are
  called inside the sending step's transaction, under the execution's lock,
  so an Oban that inserts through the repo `:repo` names commits or rolls back
  with the step.
- **One held row per dedup key.** `schedule/2` adds no second row for an
  `entry.key` the queue already holds, and answers `:ok`.
- **Cancel by `{scope, send_id}`.** `cancel/3` deletes that scope's rows for
  the send id and no other scope's, and answers `{:ok, count}`.
- **The row as the one decision point.** A fire deletes the row in the write
  that decides it fires, so a cancel and a fire of one row cannot both
  succeed. Below, the rows live in a table of the host's and an Oban job only
  wakes one.
- **The fire-time check, then the delivery.** A row whose owner has ended is
  deleted and not delivered; otherwise the route is found with
  `StatifierRouter.Config.route/3` and handed the row's own `config`, `event`
  and `key`. `StatifierRouter.TimerQueue`'s "Firing a row" says how each owner
  is checked.

```elixir
defmodule MyApp.ObanTimerQueue do
  @behaviour StatifierRouter.TimerQueue

  @impl StatifierRouter.TimerQueue
  def schedule(_queue_config, entry) do
    # MyApp.Timers.hold/1 inserts the entry unless a row with its key is
    # held, answering {:ok, row} or {:ok, nil} when one already is.
    case MyApp.Timers.hold(entry) do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        at = DateTime.add(DateTime.utc_now(), entry.delay_ms, :millisecond)

        case Oban.insert(MyApp.TimerFire.new(%{"row_id" => row.id}, scheduled_at: at)) do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl StatifierRouter.TimerQueue
  def cancel(_queue_config, scope, send_id),
    do: {:ok, MyApp.Timers.delete_all(scope, send_id)}
end

defmodule MyApp.TimerFire do
  use Oban.Worker, queue: :timers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"row_id" => row_id}}) do
    MyApp.Repo.transaction(fn ->
      # MyApp.Timers.take/1 deletes the row and answers its entry, or nil
      # when a cancel deleted it first.
      with %{} = entry <- MyApp.Timers.take(row_id),
           true <- MyApp.Timers.owner_live?(entry.scope),
           {:ok, {module, _registered}} <-
             StatifierRouter.Config.route(MyApp.Router.config(), nil, entry.route),
           {:error, reason} <- module.deliver(entry.config, entry.event, entry.key) do
        # Undoes the take, so Oban's retry finds the row again.
        MyApp.Repo.rollback(reason)
      end
    end)
  end
end
```

## Step 7. Read `:no_timer_queue` at publish

`StatifierRouter.Contracts.check/3` lists, under `:unregistered_routes`, every
`<send>` of the router's type that is never handed to the route its literal
`target` names. An entry with `reason: :no_timer_queue` is a send that writes
a literal `delay` to a registered route, on a configuration with no
`:timer_queue`:

```elixir
%{route: "doorstep_photos", location: location, reason: :no_timer_queue}
```

At execution time that send is refused as `{:no_timer_queue, send_id}` and
nothing is queued. At the executor seam the sender hears
`error.communication` carrying the send's `sendid`, and the step it sent from
stands; on a live session `perform/2` answers the refusal for the host to
report. `:timer_queue` is one value for every scope, so the finding holds in
every scope, and the remedy is a queue on the configuration rather than a
change to the chart. A `delayexpr` is not judged, so a chart with no entry may
still send a delay the queue is needed for. Whether the finding blocks a
publish is the host's decision. With the queue from Step 6 set, the entry is
gone from the check's report.
