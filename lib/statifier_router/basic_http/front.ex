defmodule StatifierRouter.BasicHTTP.Front do
  @moduledoc """
  The BasicHTTP front for durable executions: a Plug-shaped helper that
  takes one POST at an execution's location, decodes it with
  `Statifier.Send.BasicHTTP.decode/1`, and delivers the event to the
  execution the location names (ADR-0002, the Amendment of 2026-09-30,
  decisions 3 and 5).

  **A location is a bearer capability.** Anyone who holds it can post
  events to that execution, and this front authenticates nothing beyond
  possession of the location (ruled by the operator, 2026-09-30). Hand a
  location only to the parties that should reach the execution, keep it
  out of logs, serve the base URL over TLS, and rotate it with
  `StatifierRouter.BasicHTTP.rotate_location/2` when it may have leaked.

  It is Plug-shaped, not a Plug, as `StatifierRouter.Webhook` is: it adds
  no dependency on Plug or Phoenix and starts no process. The host routes
  `POST <base_url>/:token` (and, for the 405, every other method) to a
  controller action that builds the request map and calls `handle/3`, then
  answers with `response/1`. Step 3 of the guide ["How to give an execution
  an HTTP location"](how-to-give-an-execution-an-http-location.md#step-3-route-posts-to-the-front)
  shows it. `handle/3` needs a configuration that sets `:basichttp`.

  ## The request

    * `:token` - the path segment after the base URL, which the host cuts
      from the request path;
    * `:method` - the request's method, as a string;
    * `:content_type` - its `content-type` header, or `nil`;
    * `:body` - its body, as it arrived;
    * `:query` - its query string, or `nil`;
    * `:send_key` - its `scxml-send-key` header, or `nil`; optional.

  The last five are handed to `Statifier.Send.BasicHTTP.decode/1` as they
  are. A request missing one of the first five, or carrying any of them
  with the wrong type, is `{:error, {:invalid_request, keys}}`, naming the
  keys and never the token.

  ## What one request does

  The request is checked, then the token is resolved, then the request is
  decoded, then the event is delivered. While a route runs in the calling
  process the front refuses with `{:error, {:reentrant_route,
  execution_id}}` before it resolves anything, as
  `StatifierRouter.Delivery.deliver/4` does.

    * **Resolution.** A token with no location row, a string that is not
      a minted token's shape, and an address row already stamped
      `terminal_seen_at` are each `{:error, :unknown_location}`: the front
      delivers nothing and writes nothing. The answer does not say which.
    * **Delivery.** The event goes through
      `StatifierRouter.Delivery.deliver_event/4` under the plan name
      `basichttp`, the address row's document and key, `create: :never`
      and ADR-0001's default horizon, with the row's scope. That is the
      one transaction every delivery takes: the dedupe claim, the address
      lookup, the step, the ledger row, whose `binding_id` is `basichttp`.
      When the configuration gives an `:around_delivery`, the delivery
      runs inside one call of it, handed the address row's scope and the
      door `:basichttp`; the resolution before it stays outside, because
      the scope is not known until the token resolves (ADR-0003, the
      Amendment of 2026-10-02).
    * **Deduplication.** With a send key, the claim's message id is the
      execution id, `/`, and the key, so one key is deduplicated per
      execution; a request already enqueued within the horizon is a
      duplicate and nothing is enqueued. Without one, the message id is
      minted fresh and every such request is delivered. The key is the
      sender's claim, trusted as far as the location is.

  A request that fails before the delivery writes no row: before the token
  resolves there is no scope, and the ledger's `scope` is `NOT NULL`. No
  row and no error the front returns carries the token.

  ## The answer and the status

  `handle/3` answers `{:ok, outcome}`, one of
  `StatifierRouter.Delivery.deliver_event/4`'s outcomes, or `{:error,
  reason}`. `response/1` maps it to the status and headers to answer with:

  | `handle/3` answers | status | headers |
  |---|---|---|
  | `{:ok, {:delivered, "basichttp", execution_id}}` | 204 | none |
  | `{:ok, {:duplicate, "basichttp"}}` | 204 | none |
  | `{:ok, {:dropped, "basichttp", :finished}}` | 404 | none |
  | `{:ok, {:dropped, "basichttp", :no_execution}}` | 404 | none |
  | `{:error, :unknown_location}` | 404 | none |
  | `{:error, {:method_not_allowed, method}}` | 405 | `allow: POST` |
  | any other decode error | 400 | none |
  | any other `{:error, reason}` | 500 | none |

  An event the execution selects no transition for is delivered and
  answered 204: it was added to the execution's queue. A `dropped:
  finished` stamps the address row terminal, so a retry of the same POST
  resolves as an unknown location and is answered 404 again. A 500 is a
  delivery that did not settle, and a sender may retry it.
  """

  alias Statifier.Send.BasicHTTP, as: Stock
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.Config
  alias StatifierRouter.Delivery
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Location
  alias StatifierRouter.SendHandler

  import Ecto.Query, only: [from: 2]

  # The plan name the front delivers under: the ledger row's binding_id
  # and the dedupe claimant (ADR-0002, the Amendment of 2026-09-30,
  # decision 3).
  @plan_id "basichttp"

  # ADR-0001, section 1's default horizon, the one ADR-0006, section 2
  # takes for the same reason: no binding supplies one here.
  @dedupe %{by: :message_id, horizon_ms: 259_200_000}

  @typedoc "The request a host hands `handle/3`; the moduledoc describes each key."
  @type request :: %{
          required(:token) => String.t(),
          required(:method) => String.t(),
          required(:content_type) => String.t() | nil,
          required(:body) => binary(),
          required(:query) => String.t() | nil,
          optional(:send_key) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "What `handle/3` answers, and what `response/1` reads."
  @type answer :: {:ok, StatifierRouter.outcome()} | {:error, term()}

  @doc """
  Takes one request at a location, as the module documentation describes.

  `opts`: `:now`, a `DateTime` in UTC, the time the delivery's rows carry,
  defaulting to `DateTime.utc_now/0`. Any other key is
  `{:error, {:unknown_key, name}}`.
  """
  @spec handle(Config.t(), request(), keyword()) :: answer()
  def handle(config, request, opts \\ [])

  def handle(%Config{basichttp: [_ | _]} = config, request, opts)
      when is_map(request) and is_list(opts) do
    with {:ok, now} <- options(opts),
         {:ok, request} <- checked(request),
         :ok <- not_reentrant(),
         {:ok, row} <- resolve(config, request.token),
         {:ok, event} <- Stock.decode(Map.delete(request, :token)) do
      deliver(config, row, event, request, now)
    end
  end

  @doc """
  The status and headers to answer one `handle/3` answer with; the module
  documentation's table lists each.

      iex> StatifierRouter.BasicHTTP.Front.response({:ok, {:duplicate, "basichttp"}})
      {204, []}

      iex> StatifierRouter.BasicHTTP.Front.response({:error, {:method_not_allowed, "GET"}})
      {405, [{"allow", "POST"}]}
  """
  @spec response(answer()) :: {100..599, [{String.t(), String.t()}]}
  def response({:ok, {:delivered, _plan, _execution_id}}), do: {204, []}
  def response({:ok, {:duplicate, _plan}}), do: {204, []}

  def response({:ok, {:dropped, _plan, reason}}) when reason in [:finished, :no_execution],
    do: {404, []}

  def response({:error, :unknown_location}), do: {404, []}
  def response({:error, {:method_not_allowed, _method}}), do: {405, [{"allow", "POST"}]}
  def response({:error, {:not_utf8, _part}}), do: {400, []}
  def response({:error, {:malformed_send_key, _value}}), do: {400, []}
  def response(_other), do: {500, []}

  defp deliver(config, %Address{} = row, event, request, now) do
    SendHandler.put_delivery_scope(row.scope)

    plan = %{id: @plan_id, document: row.document, create: :never, dedupe: @dedupe}

    envelope = %{
      event: event,
      message_id: message_id(row.execution_id, Map.get(request, :send_key)),
      scope: row.scope,
      now: now
    }

    delivered =
      Config.around_delivery(config, row.scope, :basichttp, fn ->
        Delivery.deliver_event(config, plan, row.key, envelope)
      end)

    case delivered do
      {:error, _reason} = error -> error
      outcome -> {:ok, outcome}
    end
  after
    SendHandler.delete_delivery_scope()
  end

  # The address row a token names, joined through its location. A token
  # that is not a minted token's shape is never looked up, and a row
  # already seen terminal reaches nothing the front can deliver to. The
  # lookup binds the token, so it runs with `log: false`: Ecto's :debug
  # query log would print it (ADR-0002, the Note of 2026-10-02).
  defp resolve(config, token) do
    with true <- BasicHTTP.token?(token),
         %Address{terminal_seen_at: nil} = row <-
           config.repo.one(address_by_token(config, token), log: false) do
      {:ok, row}
    else
      _unknown -> {:error, :unknown_location}
    end
  end

  defp address_by_token(config, token) do
    from(a in Config.queryable(config, Address),
      join: l in ^Config.queryable(config, Location),
      on: l.address_id == a.id,
      where: l.token == ^token,
      select: a
    )
  end

  # The key is exactly eight `/`-separated fields (the decoder refuses any
  # other), so the execution id is everything before them whatever it
  # holds. Without a key every request is its own message.
  defp message_id(execution_id, send_key) when is_binary(send_key),
    do: execution_id <> "/" <> send_key

  defp message_id(_execution_id, nil),
    do: "basichttp/" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp not_reentrant do
    case SendHandler.sending_execution() do
      nil -> :ok
      execution_id -> {:error, {:reentrant_route, execution_id}}
    end
  end

  @required [:token, :method, :content_type, :body, :query]

  defp checked(request) do
    case Enum.reject(@required ++ [:send_key], &valid?(&1, request)) do
      [] -> {:ok, request}
      keys -> {:error, {:invalid_request, keys}}
    end
  end

  defp valid?(:send_key, request), do: nullable_string?(Map.get(request, :send_key))

  defp valid?(key, request) when key in [:content_type, :query],
    do: Map.has_key?(request, key) and nullable_string?(Map.fetch!(request, key))

  defp valid?(key, request), do: is_binary(Map.get(request, key))

  defp nullable_string?(value), do: is_nil(value) or is_binary(value)

  defp options(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_opts, opts}},
         :ok <- Config.reject_unknown(opts, [:now]) do
      case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
        %DateTime{time_zone: "Etc/UTC", microsecond: {usec, _}} = now ->
          {:ok, %{now | microsecond: {usec, 6}}}

        other ->
          {:error, {:invalid_value, :now, other}}
      end
    end
  end
end
