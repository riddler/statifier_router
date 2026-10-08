# How to take webhooks and form posts

This guide routes events that arrive over HTTP, a carrier's webhook or a
recipient's web form, into the same bindings a queue's messages reach. It
starts from a configuration the router delivers with (a host function such as
`MyApp.Router.config/0` that answers it), bindings for the source you are
adding, and a Phoenix or Plug controller of the host's own.

This package adds no dependency on Plug or Phoenix: `StatifierRouter.Webhook`
is a plain function with the shape a plug or a controller action calls, and
the host writes that action itself. Every shape below reaches the same
`StatifierRouter.route/3` the Broadway pipeline calls.

## Step 1. Keep the raw body

`raw_body` is the bytes as posted. A JSON or form body has usually been parsed
before the action runs, so a `Plug.Conn.read_body/2` there answers an empty
body, and an empty `raw_body` hashes to one constant id: every post would be
the same message. Keep the bytes in `conn.assigns.raw_body` with
`Plug.Parsers`' `:body_reader` option. It worked when
`conn.assigns.raw_body` is the posted body, not `""`, in the action.

The body is needed only to be hashed. From statifier_router 0.12.0, a
request whose `provider_id` is a non-empty string may leave `raw_body` out:
the provider id is the message id, so there is nothing to hash. A front that
hands over an id of its own, such as the id of a row in which it stored the
post, passes that id as `provider_id` and no body. On 0.11 and earlier
`raw_body` is required on every request, so such a front passes its id as
`raw_body` too. A request with neither a body nor a non-empty `provider_id`
is `{:error, {:invalid_request, request}}`, and a `raw_body` of `nil` counts
as the wrong type rather than as no body.

## Step 2. Write the webhook action

**The host verifies the signature.** This package verifies nothing; it routes
what it is handed. Below, a parcel carrier posts each scan of a parcel to the
host's controller:

```elixir
def create(conn, _params) do
  raw_body = conn.assigns.raw_body

  with :ok <- MyApp.Provider.verify(conn, raw_body) do
    answer =
      StatifierRouter.Webhook.handle(MyApp.Router.config(), %{
        scope: conn.assigns.scope,
        source: "parcel_scans",
        selector: %{"path" => conn.request_path},
        raw_body: raw_body,
        data: Jason.decode!(raw_body),
        provider_id: List.first(Plug.Conn.get_req_header(conn, "x-provider-event-id"))
      })

    send_resp(conn, StatifierRouter.Webhook.status(answer), "")
  else
    {:error, _reason} -> send_resp(conn, 401, "")
  end
end
```

A request whose signature fails verification never reaches the router: the
`else` answers `401` and nothing is routed.

The message id is the provider's event id when it sends a non-empty one, and
otherwise the lowercase hex SHA-256 of the raw body, so a provider's retry of
the same body is the same message. `status/1` answers `200` for every
recorded outcome - a duplicate, a drop, a refusal and a no-match included -
so the provider stops retrying, and `500` for an `{:error, _}`, so it
retries. The request's `selector` is carried for the host's own front and is
never read here: bindings are chosen by source alone.

Check it by posting the same signed body twice: both answer `200`, and the
second is recorded as `{:duplicate, binding_id}`.

## Step 3. Decide how several scopes share one front

A body-hash id is scope-free: the dedupe key is the binding and the message
id, and a binding carries no scope, so the same body under two scopes through
one shared binding is one message, and nothing reaches the second scope's
execution. A host that routes several scopes through one front either gives
each scope its own binding or uses a provider that sends an event id. The
example above assumes the second remedy, a provider that sends an event id:
it passes the provider's `x-provider-event-id` header as `provider_id`, so the
body hash is only its fallback.

## Step 4. Take a form post the same way

A host's own web form reaches the same `handle/3`. The shape is the webhook
front's with three differences: the host verifies its own post rather than a
provider's signature, the scope comes from the host rather than from anything
posted, and there is no provider event id.

**The host verifies its own post.** Its session, its CSRF token, whatever its
framework checks: this package verifies nothing here either. Below, a
recipient tells the parcel's execution where to leave it, from a form on the
host's tracking page:

```elixir
def create(conn, %{"safe_place" => fields}) do
  with :ok <- MyApp.Forms.verify(conn) do
    answer =
      StatifierRouter.Webhook.handle(MyApp.Router.config(), %{
        # The host's session or route, never the posted body.
        scope: conn.assigns.scope,
        source: "safe_place_form",
        raw_body: conn.assigns.raw_body,
        data: fields
      })

    case StatifierRouter.Webhook.status(answer) do
      200 -> redirect(conn, to: ~p"/parcels/safe-place/thanks")
      500 -> conn |> put_status(500) |> text("Please try again.")
    end
  else
    {:error, _reason} -> conn |> put_status(403) |> text("Forbidden")
  end
end
```

A post that fails the host's check never reaches the router: the `else`
answers `403` and nothing is routed.

**The scope is the host's.** A scope read from the posted body is a scope the
browser chose; the scope comes from the host's session or route.

**`provider_id` is absent, so the message id is the lowercase hex SHA-256 of
the raw body.** Two identical submissions are one message within one binding
for that binding's dedupe horizon: a double-clicked submit is routed once, and
the second's outcome is `{:duplicate, binding_id}`. The hash covers every
posted byte, a CSRF token field included when the form carries one, so
whether a later resubmission is a new message depends on whether the form it
came from posted the same bytes. The body hash is also scope-free, as Step 3
warns: the same body posted under two scopes through one shared binding is
one message, and nothing reaches the second scope's execution. A form has no
provider event id to fall back on, so the remedy is the other one: each scope
gets its own binding, through a `:bindings_resolver` (see
[How to bind events from several sources to one execution](how-to-bind-events-to-an-execution.md))
that answers a binding `id` of the scope's own.

**`status/1` is read for a browser, not for a provider's retry.** It answers
`200` for every recorded outcome and `500` for an `{:error, _}`, nothing else.
`200` is a redirect or a thank-you page; it says the post was recorded, not
that an execution received it, since a duplicate, a drop, a refusal and a
no-match are `200` too, and a host that tells the recipient more reads the
outcomes in `answer` itself. `500` is an error page: the attempt did not
settle, and the recipient may post again. The failed verification is the
host's own answer (`403` above), never a status from this package.

## Step 5. A form post you store first

Step 4's controller routes while the browser waits, and hands the router the
posted fields. A host that must answer the browser before any engine work, or
that keeps the posted values out of the engine's state, stores the post in a
table of its own, answers `202`, and routes the stored row's id from a job.
The engine then holds ids only, and a step that needs a posted value reads
the row by its id.

**The controller verifies, stores and answers.** Below, a recipient asks for
a parcel's delivery to move to another day, from a form on the host's
tracking page. The host's own `reschedule_requests` table holds the posted
fields (`parcel_number`, `preferred_day`, `note`), the host's scope, and the
form's one-time `form_token`, under a unique index:

```elixir
def create(conn, %{"reschedule" => fields}) do
  with :ok <- MyApp.Forms.verify(conn) do
    # The host's session or route, never the posted body.
    case MyApp.Reschedules.store(conn.assigns.scope, fields) do
      {:ok, _stored_or_already} -> conn |> put_status(202) |> text("We have your request.")
      {:error, _changeset} -> conn |> put_status(422) |> text("Please check the form.")
    end
  else
    {:error, _reason} -> conn |> put_status(403) |> text("Forbidden")
  end
end
```

The row and its job are written in one transaction, through an Oban that
inserts through the same repo, so a stored post always has a job and a
rolled-back one has neither:

```elixir
def store(scope, fields) do
  changeset = RescheduleRequest.changeset(%RescheduleRequest{scope: scope}, fields)

  Repo.transaction(fn ->
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :form_token) do
      # The same form posted again: its row and its job are already there.
      # (With an id the database generates, a skipped insert answers a nil id.)
      {:ok, %RescheduleRequest{id: nil}} ->
        :already_stored

      {:ok, request} ->
        Oban.insert!(MyApp.RouteReschedule.new(%{"request_id" => request.id}))
        :stored

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end)
end
```

**The job routes the stored row's id.** It reads the row for its scope and
its id and calls the same `handle/3`:

```elixir
defmodule MyApp.RouteReschedule do
  use Oban.Worker, queue: :reschedules

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id}}) do
    request = MyApp.Repo.get!(MyApp.RescheduleRequest, request_id)
    id = to_string(request.id)

    answer =
      StatifierRouter.Webhook.handle(MyApp.Router.config(), %{
        # Stored with the row from the host's session, never from the body.
        scope: request.scope,
        source: "reschedule_form",
        provider_id: id,
        # Ids only: no posted field travels with the event.
        data: %{"kind" => "reschedule_requested", "request_id" => id}
      })

    case StatifierRouter.Webhook.status(answer) do
      200 -> :ok
      500 -> {:error, answer}
    end
  end
end
```

**Which version needs which.** From statifier_router 0.12.0 the request above
is complete: its `provider_id` is a non-empty string, so it is the message
id and `raw_body` is left out (Step 1). On 0.11 and earlier `raw_body` is
required, so the job passes the same id twice, `provider_id: id, raw_body: id`;
the provider id still wins, so the message id is the same on both.
`provider_id` must be a string: the job converts the row's integer id with
`to_string/1`, and the same string is the key below.

**`status/1` is read for a job.** `500` is the job's `{:error, _}`, so the job
runner retries it with its own backoff; what an earlier attempt wrote for a
binding stays written, and the retry carries the same message id, so a
binding that already took it answers `{:duplicate, binding_id}`. `200` is
done: every recorded outcome, a duplicate, a drop, a refusal and a no-match
included, is an answer a retry would not change.

**The binding keys on the stored id, so one execution per submission.**

```elixir
%{id: "reschedule_form_to_request", source: "reschedule_form",
  match: ~s(event.kind == "reschedule_requested"), key: "event.request_id",
  document: "parcel_reschedule", event: "reschedule.requested",
  data: ["request_id"]}
```

Every stored row has its own id, so under the default `create: :if_absent`
each one opens its own execution, which is handed the request id and reads
the rest from the row. The id is the host table's own, unique across scopes,
so the scope-free hazard of Step 3 does not arise.

**Two dedupe layers, the host's first.** A browser's or a person's second
post of the same form is a second request to the controller, and stored
without a key of the host's it would be a new row with a new id, a new
message and a new execution. The host's unique index on `form_token` is the
first layer: the second post stores nothing and enqueues nothing. The
router's claim on the binding and the message id
(`StatifierRouter.Dedupe.claim/4`) is the second: a job that runs twice for
one row is one message, and the second delivery is `{:duplicate, binding_id}`.
That claim lasts for the binding's dedupe horizon, its `dedupe.horizon_ms`
(three days by default); after it, the same id is a new message again and
is routed to whatever execution its address names.

**A reaped execution means a new one.** Once the request's execution has
finished, its address row lives for the longest dedupe horizon of any
enabled binding naming its document, counted from when
`StatifierRouter.Addresses.reap/3` first reads it finished, and a reap
after that deletes it. A later post routed with the same id, the row's job
enqueued again say, then finds no row and, under `create: :if_absent`,
opens a new execution. A host that must not reopen a request routes its id
again only within that horizon.

The reference host, [statifier_examples](https://github.com/riddler/statifier_examples),
walks recipes that put the family's packages together in an application of
its own.
