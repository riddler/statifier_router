# How to give an execution an HTTP location

This guide gives each parcel's durable execution an HTTP location of its own,
so a van's scanner can post events straight to it, and lets the chart send
over HTTP in turn. It starts from a configuration the router delivers with, a
host controller that can take a POST, and an executor of the host's own.

The protocol is the W3C Basic HTTP Event I/O Processor (SCXML appendix C.2).
statifier ships the processor and a pure decoder for the POST; this package
adds the location of a persisted execution and the front that delivers to it
(ADR-0002, the Amendment of 2026-09-30).

Two facts to hold before you start:

**A location is a bearer capability.** Anyone who holds it can post events to
that execution, and the router authenticates nothing beyond possession of the
location. Hand a location only to the parties that should reach the
execution, keep it out of logs and out of URLs shown to others, serve the base
URL over TLS, and rotate it when it may have leaked.

**The token is part of the execution's persisted state.** The location is
written into the execution's `_ioprocessors` when the execution starts, and a
persisted position carries it, so statifier_persistence binds the token on the
create and on every step, and keeps it at rest in the clear unless the host
passes that package an encrypting `:blob_type`. This package keeps the token
out of its own query log only: its three statements that bind it run with
Ecto's `log: false`, and the repo's query telemetry event still carries their
parameters. Rotate a location that may have leaked, and never run a
production repo or logger at `:debug` (ADR-0002, the Note of 2026-10-02 on the
query log).

## Step 1. Create the location table

The location table is opt-in and outside the version walk. Add the migration
in [Upgrading the tables](../upgrading.md) ("The opt-in location table") after
the ones you have, and run it. It worked when the table exists under your
`:table_prefix`.

## Step 2. Set `:basichttp` on the configuration

Set `:basichttp` with the base URL the front answers at:

```elixir
StatifierRouter.Config.new(
  repo: MyApp.Repo,
  # ... the delivery options ...
  basichttp: [base_url: "https://depot.example/scxml"]
)
```

From then on each execution created under a new address row gets a location:
the base URL, `/`, and a 43-character token the router mints, never the
execution id. The chart reads it at `_ioprocessors['basichttp']['location']`
and can hand it to whoever should reach it; the host reads it with
`StatifierRouter.BasicHTTP.location/2` and replaces it with
`StatifierRouter.BasicHTTP.rotate_location/2`, after which the old location
answers `404`. Rotation does not reach the chart's own copy, which statifier
writes once when the execution starts: after a rotation the chart still reads
the old location. An execution created under `:always_new` has no address row
and no location.

Check it by routing a parcel's first scan and reading
`StatifierRouter.BasicHTTP.location/2` for its execution: it answers
`{:ok, location}`, the base URL and a token; `{:error, :no_location}` means
the execution has none.

## Step 3. Route POSTs to the front

The front is `StatifierRouter.BasicHTTP.Front`, Plug-shaped as the webhook
helper is. The host routes `POST <base_url>/:token` (and every other method,
for the `405`) to an action like this one:

```elixir
def event(conn, %{"token" => token}) do
  {:ok, body, conn} =
    case conn.assigns do
      %{raw_body: raw_body} -> {:ok, raw_body, conn}
      _body_not_parsed -> Plug.Conn.read_body(conn)
    end

  answer =
    StatifierRouter.BasicHTTP.Front.handle(MyApp.Router.config(), %{
      token: token,
      method: conn.method,
      content_type: List.first(Plug.Conn.get_req_header(conn, "content-type")),
      body: body,
      query: conn.query_string,
      send_key: List.first(Plug.Conn.get_req_header(conn, "scxml-send-key"))
    })

  {status, headers} = StatifierRouter.BasicHTTP.Front.response(answer)
  conn |> Plug.Conn.merge_resp_headers(headers) |> Plug.Conn.send_resp(status, "")
end
```

**`body` is the bytes as posted.** A form-encoded POST has usually been parsed
before the action runs, so the action takes the bytes the endpoint's
`:body_reader` kept, as the webhook front does; a body the parsers pass
unread, such as a `<content>` send's `text/plain`, it reads itself.

A parcel's execution that handed its location to the van's scanner takes each
`_scxmleventname=delivered` POST as the event `delivered` and answers `204`
once it is delivered. The statuses: `204` for a delivered event or a
duplicate, `404` for a location that reaches no execution (unknown, rotated
away, or finished), `405` with `Allow: POST` for another method, `400` for a
body or send key the decoder refuses, and `500` for a delivery that did not
settle. A POST that carries statifier's `scxml-send-key` header is delivered
once per execution within the default dedupe horizon of 72 hours; one without
it is delivered every time.

## Step 4. Send from a durable execution

A chart can also send with `<send type="basichttp">`. A durable execution has
no session to perform that send, so the effect reaches the host's executor,
and the host performs it (ADR-0002, the Amendment of 2026-10-02). The
recommended shape plans the send at the executor seam, inserts a job for it
inside the delivery's transaction, and performs it after the delivery
commits: the job commits with the step that sent, no POST leaves for a step
that rolled back, and a slow receiver holds no transaction and no lock. It is
the transactional outbox of
[How to deliver a chart's sends to a sink](how-to-deliver-to-a-sink.md), with
the job row as the outbox row.

The example is a parcel loaded onto the van, whose execution tells the depot's
manifest desk and waits; a failed POST returns the parcel to the depot:

```xml
<state id="on_van">
  <onentry>
    <send id="manifest" type="basichttp" target="https://depot.example/manifests" event="parcel.loaded"/>
  </onentry>
  <transition event="delivered" target="doorstep"/>
  <transition event="error.communication" cond="_event.sendid == 'manifest'" target="returned_to_depot"/>
</state>
```

**The executor plans and inserts.** `StatifierRouter.BasicHTTP.deliver/3` is
pure and answers the instructions to perform; the executor runs in the
delivery's process, so the job insert joins its transaction:

```elixir
defmodule MyApp.Executor do
  alias Statifier.Effect.{Send, SendDelayed}

  @types ["http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor", "basichttp"]

  def execute({:send, %Send{type: type} = send}, %{execution_id: execution_id})
      when type in @types do
    ctx = %{session_id: execution_id, opts: MyApp.Router.basichttp_options()}
    event = Statifier.Send.Event.build(send, execution_id)
    {:ok, instructions} = StatifierRouter.BasicHTTP.deliver(send, event, ctx)

    Enum.reduce_while(instructions, :ok, fn
      {:handler, _module, payload}, :ok ->
        MyApp.Repo.insert!(MyApp.SendJob.new(execution_id, send, payload, ctx),
          on_conflict: :nothing,
          conflict_target: [:key]
        )

        {:cont, :ok}

      _not_a_post, :ok ->
        {:halt, {:error, {:basichttp_send_not_planned, send.send_id}}}
    end)
  end

  # A delayed BasicHTTP send is not delivered by this package (ADR-0002,
  # the Note of 2026-10-04): refuse it, and the chart sees
  # error.communication with _event.sendid the send's id and no data.
  def execute({:send_delayed, %SendDelayed{type: type} = send}, _context)
      when type in @types,
      do: {:error, {:delayed_basichttp_send, send.send_id}}

  def execute(_effect, _context), do: :ok
end
```

`MyApp.SendJob.new/4` writes the payload and the context out as the outbox
example writes its event, `:erlang.term_to_binary/1`, beside the execution
id, the send's id and the job's key; `MyApp.Router.basichttp_options/0` is
the host's own accessor for the `:basichttp` options it configured. The key is
the send's dedup key written out - the execution id, `send_id`, `macrostep`,
`microstep`, `round`, `c_index`, `owner` and `ordinal`, each `nil` written as
a fixed spelling of its own - so a redriven step, which re-emits the same send
with the same fields, inserts one job. A send with no target plans no POST,
and the executor's `{:error, _}` for it reaches the execution as
`error.communication`.

## Step 5. Perform the job after the commit, and bring a failure back

The worker sees only committed jobs. A failure comes back through
`StatifierRouter.Delivery.deliver_event/4`:

```elixir
defmodule MyApp.SendJob.Worker do
  alias StatifierRouter.{Addresses, BasicHTTP, Delivery}

  @plan %{
    id: "basichttp_failure",
    create: :never,
    dedupe: %{by: :message_id, horizon_ms: 259_200_000}
  }

  def perform(job) do
    {payload, ctx} = :erlang.binary_to_term(job.instruction)

    case BasicHTTP.perform(payload, ctx) do
      :ok -> :ok
      {:error, reason} -> failed(job, reason)
    end
  end

  # Called once the job's own retries are spent, or at once.
  defp failed(job, reason) do
    case Addresses.by_execution(MyApp.Router.config(), job.execution_id) do
      nil ->
        MyApp.DeadLetters.record(job.key, reason)

      row ->
        event =
          Statifier.Event.external("error.communication",
            sendid: job.send_id,
            data: %{"reason" => inspect(reason)}
          )

        MyApp.Router.config()
        |> Delivery.deliver_event(Map.put(@plan, :document, row.document), row.key, %{
          event: event,
          message_id: job.key,
          scope: row.scope,
          run_in_scope: true,
          now: DateTime.utc_now()
        })
        |> settled(job, reason)
    end
  end

  defp settled({:delivered, _plan, _execution_id}, _job, _reason), do: :ok
  defp settled({:duplicate, _plan}, _job, _reason), do: :ok
  defp settled({:dropped, _plan, _why}, job, reason), do: MyApp.DeadLetters.record(job.key, reason)
  defp settled({:error, _reason} = error, _job, _reason_sent), do: error
end
```

`deliver_event/4` is the only way back in: it takes the same dedupe claim, the
same address lookup and writes the same ledger row as every delivery, under
the plan's `id`. Name that `id` yourself: neither `execution` nor
`basichttp`, and no binding's. `create: :never` because a failure reaches an
execution that exists and never makes one. The event arrives as an external
event in a step of its own, carrying the failed send's id in
`_event.sendid`. A retried job's second delivery is
`{:duplicate, "basichttp_failure"}`. An execution that has already finished
answers `{:dropped, "basichttp_failure", :finished}`, and one whose address
row is gone answers `nil` from `by_execution/2` or `:no_execution` from the
delivery: the miss is then a dead letter, keyed by the job's key.
`{:error, _}` is a delivery that did not settle, and the job retries it. A
chart with no transition for `error.communication` where it stands still
answers `{:delivered, ...}`: the event is in its input log, and nothing took
it.

`run_in_scope: true` runs the step the delivery causes under the address
row's scope, as a binding's delivery does, so a send the chart's
`error.communication` handler makes to a route that a scope in
`:route_overrides` overrides resolves in that scope (ADR-0002, the Amendment
of 2026-10-04). Without it, `deliver_event/4` sets no scope of its own, and
such a send is refused as `{:no_delivery_scope, name}` in that step. The scope
is set for the length of the call only: any scope the calling process held
before is put back.

**Performing inline is allowed.** The executor may call
`StatifierRouter.BasicHTTP.perform/2` itself and answer its
`{:error, reason}`, which reaches the execution as `error.communication`
within the same step, with no job and no `deliver_event/4`. The POST is then
made inside the delivery's transaction: a slow receiver holds the
transaction, the execution's lock and, on SQLite, the database's write lock,
and a delivery that rolls back after the POST has sent it anyway.
