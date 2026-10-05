# How to take webhooks and form posts

This guide routes events that arrive over HTTP, a carrier's webhook or a
recipient's web form, into the same bindings a queue's messages reach. It
starts from a configuration the router delivers with (a host function such as
`MyApp.Router.config/0` that answers it), bindings for the source you are
adding, and a Phoenix or Plug controller of the host's own.

This package adds no dependency on Plug or Phoenix: `StatifierRouter.Webhook`
is a plain function with the shape a plug or a controller action calls, and
the host writes that action itself. Both shapes below reach the same
`StatifierRouter.route/3` the Broadway pipeline calls.

## Step 1. Keep the raw body

`raw_body` is the bytes as posted. A JSON or form body has usually been parsed
before the action runs, so a `Plug.Conn.read_body/2` there answers an empty
body, and an empty `raw_body` hashes to one constant id: every post would be
the same message. Keep the bytes in `conn.assigns.raw_body` with
`Plug.Parsers`' `:body_reader` option. It worked when
`conn.assigns.raw_body` is the posted body, not `""`, in the action.

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
