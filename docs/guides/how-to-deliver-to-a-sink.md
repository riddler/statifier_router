# How to deliver a chart's sends to a sink

This guide takes a `<send>` in a parcel's chart all the way to a system
outside it, a carrier's pickup booking here, and brings the carrier's answer
back into the execution. It starts from a configuration the router delivers
with and a chart you can add `<send>` elements to. The sink itself is the
host's: this package resolves the route and hands it the event, and the host
decides what the route writes to and how it retries.

## Step 1. Name a route in the chart

A chart reaches the outside world with `<send>`. The `type` names the host's
processor and the `target` names a **route**: an opaque string this package
resolves against the host's registry, which the engine never parses.

```xml
<send type="myapp:sink" target="carrier_pickup" event="pickup.requested"/>
<send type="myapp:sink" target="dead_letter" event="parcel.unroutable"/>
```

## Step 2. Register the route and the send type

The host registers each route once and gives the handler the one type string
it answers to. `:send_type` is what puts the engine-visible `send_types:`
snapshot into `:persistence_options`, so every create and every step of every
delivery carries it:

```elixir
StatifierRouter.Config.new(
  repo: MyApp.Repo,
  store: store,
  resolver: resolver,
  chart_resolver: chart_resolver,
  bindings: bindings,
  send_type: "myapp:sink",
  route_adapters: %{
    "carrier_pickup" => {MyApp.OutboxRoute, %{queue: "pickups"}},
    "dead_letter" => {MyApp.OutboxRoute, %{queue: "unroutable"}}
  },
  route_overrides: %{"staging" => %{"carrier_pickup" => %{queue: "staging_pickups"}}},
  executor: &MyApp.Executor.execute/2
)
```

A scope overrides a route's **configuration** and never its **existence**: a
staging scope may point `carrier_pickup` at another queue, and cannot make a
third route appear or take one away. A chart that names a route fails the
same way in every scope.

A delivery names the scope its sends resolve in. A live `Statifier.Session` is
reached by no delivery, so the host names it in the configuration instead:
`processor_scope: "staging"`, or a zero-arity fun the handler calls once for
each send and that answers the scope or `nil`. The chart never names a scope.

`StatifierRouter.Contracts.check/3` reports, under `:unregistered_routes`,
every `<send>` of the router's type whose literal `target` names no
registered route; an empty list there is the check that this step worked. At
run time a send whose `target` names no registered route is reported to the
sender, leaves the step it was sent from standing, and writes one
`send_refused` routing-ledger row.

## Step 3. Write the route adapter

A route adapter implements `StatifierRouter.Route`. It is handed its own
configuration, the built event and an idempotency key, and it answers `:ok` or
`{:error, reason}`:

```elixir
defmodule MyApp.OutboxRoute do
  @behaviour StatifierRouter.Route

  @impl true
  def deliver(%{queue: queue}, event, key) do
    MyApp.Repo.insert!(
      %MyApp.Outbox{
        queue: queue,
        key: MyApp.Outbox.key(key),
        event: :erlang.term_to_binary(event)
      },
      on_conflict: :nothing,
      conflict_target: [:queue, :key]
    )

    :ok
  end
end
```

The outbox row carries the key under a unique index, and `on_conflict:
:nothing` makes a re-emitted send insert once. The table, the key's string
form and the worker that drains the rows are the next step.

**A route is one-way.** It returns no data into the chart. A sink's result -
accepted, rejected, an id - comes back as a new inbound event through a
binding, correlated by the author-written send `id` the adapter echoes, with
the chart arming its own timeout as a delayed self-send. The one thing an
`{:error, _}` causes in the sending execution is `error.communication`
carrying that send's `sendid`.

**A route runs inside the delivery's transaction**, under the execution's
lock, so it may only hand off durably: a job inserted on the host's own repo
joins that transaction, which is a transactional outbox for free. It must
never call back into the sending execution, and
`StatifierRouter.Delivery.deliver/4` refuses the call it can see.

`StatifierRouter.SendHandler` is the module both host shapes reach - a
process-less host calls `handle_effect/3` from its executor, a live
`Statifier.Session` registers the module itself - and
`StatifierRouter.TimerQueue` is the durable queue a delayed route send is
recorded on, keyed by `{scope, send_id}`. The rules are ADR-0005's.

## Step 4. Build the transactional outbox, end to end

The step above says what a route may do where it is called. This is the whole
path a host builds around it, from the `<send>` to the sink's answer. The
example is a parcel scanned at the depot, whose execution books a pickup with
a carrier:

```xml
<send type="myapp:sink" target="carrier_pickup" id="book_pickup" event="pickup.requested">
  <param name="parcel_id" expr="parcel_id"/>
</send>
```

registered on the same `MyApp.OutboxRoute` as above:

```elixir
route_adapters: %{"carrier_pickup" => {MyApp.OutboxRoute, %{queue: "pickups"}}}
```

**The insert, inside the delivery's transaction.** The outbox is a table on
the host's own repo, and the route's insert is the only thing the route does.
At the executor seam that insert joins the delivery's transaction, so the row
commits with the step that emitted the send and a delivery that rolls back
takes the row with it: nothing is handed off for a step that never committed.

```elixir
create table(:outbox) do
  add :queue, :string, null: false
  add :key, :string, null: false
  add :event, :binary, null: false
  add :sent_at, :utc_datetime_usec
  timestamps()
end

create unique_index(:outbox, [:queue, :key])
```

```elixir
defmodule MyApp.Outbox do
  use Ecto.Schema

  schema "outbox" do
    field :queue, :string
    field :key, :string
    field :event, :binary
    field :sent_at, :utc_datetime_usec
    timestamps()
  end

  # The router's key is a term; the unique index compares strings. Every
  # component was fixed when the send was executed, so the same send
  # always writes the same string.
  def key({scope, position, ordinal}) do
    [
      scope,
      position.send_id,
      position.macrostep,
      position.microstep,
      position.round,
      position.c_index,
      position.owner,
      ordinal
    ]
    |> Enum.map_join("/", &part/1)
  end

  defp part(value) when is_binary(value), do: value
  defp part(value), do: inspect(value)
end
```

The key is `t:StatifierRouter.Route.idempotency_key/0`: the scope half (the
execution id at the executor seam, the session id on a live session), where in
the step the send sat, and the ordinal, which is `nil` for the `:on_complete`
hook. It comes from the router with the event; the host writes it out and
invents nothing.

**The unique key, with `on_conflict: :nothing`.** Effect execution is
at-least-once: a re-driven event re-emits the same effects with the same
deterministic fields, so a repeat of one send writes the same key, and the
unique index with `on_conflict: :nothing` makes it one row. At the executor
seam a delivery that rolled back left no row behind, and its redrive writes
the row again; on a live session nothing rolls back, and the index is what
makes a repeat insert once.

**The drain, after commit.** A worker of the host's own reads rows that have
not been sent and makes the external call. It sees only committed rows, so it
never sends for a step that rolled back, and it runs outside any delivery, so
the sending execution's lock is not held while the carrier answers. This
package starts no process; the host schedules the drain as it schedules the
reapers.

```elixir
defmodule MyApp.OutboxDrain do
  import Ecto.Query

  def drain_one(queue) do
    MyApp.Repo.transaction(fn ->
      row =
        from(o in MyApp.Outbox,
          where: o.queue == ^queue and is_nil(o.sent_at),
          order_by: o.id,
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> MyApp.Repo.one()

      if row do
        event = :erlang.binary_to_term(row.event)
        :ok = MyApp.Carrier.book_pickup(event.data, idempotency_key: row.key)
        MyApp.Repo.update!(Ecto.Changeset.change(row, sent_at: DateTime.utc_now()))
      end
    end)
  end
end
```

When the job queue lives in the same database, the job row IS the outbox row:
a route that inserts a job on the host's own repo from the calling process
joins the delivery's transaction exactly as the insert above does, and the
job's worker is the drain. The job's arguments carry the written-out key, and
whatever keeps a second job for one key from being inserted plays the part of
the unique index. That queue is the host's own dependency; this package
depends on none.

**The key carried to the sink.** The worker hands the row's key to the sink
as the sink's own idempotency key. It was fixed when the row was written, and
the worker never generates one: a worker can succeed at the carrier and crash
before it marks the row sent, and the retry must be the same request under
the same key, which a sink that dedupes on its key answers without booking a
second pickup. A key minted per attempt makes every retry new work.

**The live-session shape has no delivery transaction.** On a live
`Statifier.Session`, `StatifierRouter.SendHandler`'s `perform/2` calls the
same route with no delivery transaction open. The insert commits on its own
rather than with the step, and `perform/2` may be called more than once for
one send, each time with the same key. The same route module, the same unique
index and the same conflict option serve that shape unchanged; there the
index is the whole of what makes a repeat harmless.

Check it by routing the event that sends twice: the outbox holds one row for
the send, and a delivery you make fail after the send holds none.

## Step 5. Route the sink's answer back in as an event

`deliver/3` answers only `:ok` or `{:error, reason}`, and the carrier's answer
never travels back through it. The drain, or the carrier's own webhook,
routes the answer as a new inbound event through a binding, echoing the
author-written send id the stored event carries in `sendid`, and deriving the
message id from the row's key so that routing the same answer twice is a
duplicate:

```elixir
%{id: "pickups_to_parcel", source: "carrier",
  match: ~s(event.kind == "pickup_booked"), key: "event.parcel_id",
  document: "parcel_delivery", event: "pickup.booked"}
```

```elixir
StatifierRouter.route(config, %{
  scope: scope,
  source: "carrier",
  message_id: "pickup_booked/" <> row.key,
  data: %{
    "kind" => "pickup_booked",
    "parcel_id" => event.data["parcel_id"],
    "send_id" => event.sendid,
    "booking_id" => booking_id
  }
})
```

`scope` is the host's own, the scope the parcel's execution is addressed
under. The chart waits for `pickup.booked` in the state that sent, and arms
its own timeout as a delayed self-send. The answer arrived when `route/3`
answers `{:ok, [{:delivered, "pickups_to_parcel", execution_id}]}`; routing
it a second time answers `{:duplicate, "pickups_to_parcel"}`.

## Step 6. Tell a sink that an execution has finished

There are two ways to tell a sink that an execution has ended, one written in
the chart and one configured in the host.

**In the chart**, a `<final>` sends on its way in. `<onentry>` on a top-level
`<final>` runs as part of the step that finishes the execution, so the send is
emitted on that step and reaches the route inside that delivery's
transaction:

```xml
<final id="delivered">
  <onentry>
    <send type="myapp:sink" target="delivery_records" event="parcel.delivered">
      <param name="parcel_id" expr="parcel_id"/>
    </send>
  </onentry>
</final>
```

Nothing else is needed: the send is an ordinary route send, the chart chooses
what travels in its `<param>`s, and a chart that ends in several finals can
send a different shape from each. What this pattern does not reach is the
execution's donedata, which is not addressable from executable content; that
is the second way.

**In the host**, `:on_complete` names a registered route that an execution's
donedata is handed to when a delivery through this package finishes it,
whichever `<final>` it settled in. Every door this package owns delivers that
way; a host that calls `StatifierPersistence.Executions.create/4` or `step/5`
itself reaches past the router, and a termination reached that way fires
nothing:

```elixir
StatifierRouter.Config.new(
  repo: MyApp.Repo,
  store: store,
  resolver: resolver,
  chart_resolver: chart_resolver,
  bindings: bindings,
  send_type: "myapp:sink",
  route_adapters: %{"delivery_records" => {MyApp.OutboxRoute, %{queue: "delivered"}}},
  on_complete: "delivery_records",
  executor: &MyApp.Executor.execute/2
)
```

The route is handed a `done.execution` event whose `data` is the donedata
verbatim - `:undefined`, statifier's no-value marker, for a `<final>` that
carries none - and whose `origin` is the execution id, under an idempotency
key of that execution id, the counters the finishing step reported, and no
ordinal.

The hook fires on the delivery that finishes the execution and on no other. A
later delivery to the same execution is `{:dropped, binding_id, :finished}`
and fires nothing. That is not a convenience: donedata exists only on the
answer of the call that produced it, and a hook that re-read the execution
record afterwards would be handed `nil` every time, with no error and no
warning - `StatifierPersistence.Execution.from_record/1` sets the field to
`nil` on every struct built from a stored row, because a position that has
reached a final state has no configuration left to carry one.

A route named by `:on_complete` must be in `:route_adapters`;
`StatifierRouter.Config.new/1` refuses an unregistered name rather than
missing on the one delivery that had something to hand over. An `{:error, _}`
from the route settles that delivery as
`{:error, {:on_complete, route_name, reason}}`, which rolls it back: a
terminal execution has no `error.communication` transition left to take, so
rolling back and being redriven is the only way the hand-off is not lost.

That makes a route that never succeeds a poison pill. The finishing delivery
never commits, so the execution stays where it was before that step, and
every time the source hands the message over again the step re-runs, its
effects are re-emitted, the route fails again and the front sees the same
message fail. Wire only a route that is safe to call again under the same
idempotency key and that eventually succeeds: this package retries nothing
and holds no failed message, so the source's own redelivery policy is the
only bound on the attempts. `StatifierRouter.Config`'s documentation of
`:on_complete` says the same where the option is set.
