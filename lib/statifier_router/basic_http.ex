defmodule StatifierRouter.BasicHTTP do
  @moduledoc """
  The W3C Basic HTTP Event I/O Processor for durable executions: the
  processor this package registers for a configuration that sets
  `:basichttp`, and the location of each execution it reaches (ADR-0002,
  the Amendment of 2026-09-30).

  **A location is a bearer capability.** Anyone who holds it can post
  events to that execution, and the router authenticates nothing beyond
  possession of the location (ruled by the operator, 2026-09-30). Hand a
  location only to the parties that should reach the execution, keep it
  out of logs and out of URLs shown to others, serve the base URL over
  TLS, and rotate it with `rotate_location/2` (or `rotate_location/3`, to
  re-stamp a live session as well) when it may have leaked.

  ## Registering it

  Set `:basichttp` on `StatifierRouter.Config` with the base URL the
  host's front answers at:

      StatifierRouter.Config.new(
        repo: MyApp.Repo,
        # ... the delivery options ...
        basichttp: [base_url: "https://example.org/scxml"]
      )

  The snapshot the configuration builds then registers this module under
  the processor's URI, `http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor`,
  and its short form `basichttp`, with the key's options:

    * `:base_url` (required) - a non-empty string, the address
      `StatifierRouter.BasicHTTP.Front` answers at. A location is this
      URL, `/`, and the execution's token.
    * `:transport` - a `Statifier.Send.BasicHTTP.Transport` module the
      outbound POSTs go through; left out, statifier's default.

  The key needs the location table `StatifierRouter.Migrations.V04`
  creates.

  ## The location

  When a delivery creates an execution under an address row it has just
  inserted, it mints a token - 32 random bytes as unpadded URL-safe
  base64, 43 characters from `A-Z a-z 0-9 - _` - stores it beside the
  address row, and hands it to this module's `ioprocessors_entry/2`
  through the create's registration, so the execution's `_ioprocessors`
  carries `base_url <> "/" <> token` under both type strings. The token is
  derived from nothing: not the address, not the execution id.

  An execution created under `:always_new` has no address row and so no
  location: its entry carries no `"location"` key. An execution created
  before the key was set has no location either, until `rotate_location/2`
  gives it one; its own `_ioprocessors`, written when it started, stays as
  it was.

  `location/2` reads an execution's current location and
  `rotate_location/2` replaces its token, after which the old location is
  answered 404 by the front. Both build the location from the
  configuration's current base URL. A host that rotates hands the new
  location to whoever should hold it.

  ## Rotation and the chart's own copy

  statifier writes an execution's `_ioprocessors` entry when the execution
  starts, so a rotation alone leaves the chart reading the location it
  started with, which no longer answers. Two shapes follow:

    * **A live session.** `rotate_location/3` with `session:` naming the
      host's running `Statifier.Session` rotates the token and then
      re-stamps that session through `Statifier.Session.replace_send_type/3`,
      under the processor's URI first and then `basichttp`, with this
      module's registration carrying the new token. The chart reads the new
      location from the next event the session processes.
    * **A durable execution's stored entry.** The entry an execution
      persisted when it started stays as it was: it carries the old
      location until the host refreshes it. `rotate_location/3` reaches a
      session the host names, never a stored execution.

  The token moves first and never waits on the session: the upsert has
  committed before the session is asked, so every answer after it carries
  the new location, `{:ok, location}` when both re-stamps answered `:ok`
  and `{:error, {:session_not_restamped, location, reason}}` when one did
  not. `reason` is the engine's own refusal, from the first type string
  that refused, or `:replace_send_type_unavailable` when the statifier in
  use exports no `Statifier.Session.replace_send_type/3` (it does from
  2.13.0; the requirement stays `~> 2.10`, so on an older statifier the
  call is never made). A refused URI stops there, and both entries carry
  the old location. A refused `basichttp` after an accepted URI leaves the
  URI entry carrying the new location and the `basichttp` entry the old
  one.

  `Statifier.Session.replace_send_type/3` is a `GenServer.call` with its
  default 5-second timeout, and `rotate_location/3` does not catch it: a
  session that is not alive, or one that does not answer in time, exits
  the caller as the engine's own call does, after the token has moved.
  `location/2` then reads the new location. A timeout does not withdraw
  the request, so the session may still apply the re-stamp later.

  ## Outbound

  `deliver/3`, `cancel/2` and `perform/2` hand each call to
  `Statifier.Send.BasicHTTP` unchanged: the outbound half is statifier's
  processor.
  """

  @behaviour Statifier.Send.Processor

  import Ecto.Query, only: [from: 2]

  alias Statifier.Send.BasicHTTP, as: Stock
  alias StatifierRouter.Addresses
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Location

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
  @short "basichttp"

  # The alphabet and length of a minted token: 32 bytes as unpadded
  # URL-safe base64.
  @token_bytes 32
  @token_shape ~r/\A[A-Za-z0-9_-]{43}\z/

  # The two type strings this module is registered under: the processor's
  # URI and its short form.
  @doc false
  @spec type_strings() :: [String.t()]
  def type_strings, do: [@uri, @short]

  @doc """
  The `_ioprocessors` entry for `type`: `%{"location" => base_url <> "/" <>
  token}` when the registration carries a `:location_token`, and `%{}`,
  an entry with no location, when it does not.
  """
  @impl Statifier.Send.Processor
  @spec ioprocessors_entry(String.t(), Statifier.Send.Processor.entry_context()) :: map()
  def ioprocessors_entry(_type, %{opts: opts}) do
    case {Keyword.fetch(opts, :base_url), Keyword.fetch(opts, :location_token)} do
      {{:ok, base_url}, {:ok, token}} when is_binary(base_url) and is_binary(token) ->
        %{"location" => location_string(base_url, token)}

      _no_location ->
        %{}
    end
  end

  @doc "Plans one send with `Statifier.Send.BasicHTTP.deliver/3`, unchanged."
  @impl Statifier.Send.Processor
  @spec deliver(
          Statifier.Effect.Send.t() | Statifier.Effect.SendDelayed.t(),
          Statifier.Event.t(),
          Statifier.Send.Processor.ctx()
        ) :: {:ok, [Statifier.Send.Processor.instruction()]}
  def deliver(send, event, ctx), do: Stock.deliver(send, event, ctx)

  @doc "Plans one cancellation with `Statifier.Send.BasicHTTP.cancel/2`, unchanged."
  @impl Statifier.Send.Processor
  @spec cancel(Statifier.Effect.Cancel.t(), Statifier.Send.Processor.ctx()) ::
          {:ok, [Statifier.Send.Processor.instruction()]}
  def cancel(cancel, ctx), do: Stock.cancel(cancel, ctx)

  @doc "Performs one instruction with `Statifier.Send.BasicHTTP.perform/2`, unchanged."
  @impl Statifier.Send.Processor
  @spec perform(term(), Statifier.Send.Processor.ctx()) :: :ok | {:error, term()}
  def perform(payload, ctx), do: Stock.perform(payload, ctx)

  @doc """
  The current location of the execution `execution_id`, as `{:ok,
  location}`, or `{:error, :no_location}` when its address row has no
  location or no address row names it.
  """
  @spec location(Config.t(), String.t()) :: {:ok, String.t()} | {:error, :no_location}
  def location(%Config{basichttp: [_ | _] = basichttp} = config, execution_id)
      when is_binary(execution_id) do
    query =
      from(l in Config.queryable(config, Location),
        join: a in ^Config.queryable(config, Address),
        on: a.id == l.address_id,
        where: a.execution_id == ^execution_id,
        order_by: a.id,
        limit: 1,
        select: l.token
      )

    case config.repo.one(query) do
      nil -> {:error, :no_location}
      token -> {:ok, location_string(Keyword.fetch!(basichttp, :base_url), token)}
    end
  end

  @doc """
  Mints a new token for the execution `execution_id` and makes it its
  location, in one statement that inserts the location of its address row
  or replaces its token. From the commit on, the old location reaches
  nothing and the front answers it 404.

  Returns `{:ok, location}`, the new location, or `{:error, {:no_address,
  execution_id}}` when no address row names the execution, which is what
  an `:always_new` execution answers.
  """
  @spec rotate_location(Config.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:no_address, String.t()}}
  def rotate_location(%Config{basichttp: [_ | _]} = config, execution_id)
      when is_binary(execution_id),
      do: rotate_location(config, execution_id, [])

  @doc """
  Rotates the location of the execution `execution_id` as
  `rotate_location/2` does and, with `session:`, re-stamps the host's live
  session with it (the moduledoc's "Rotation and the chart's own copy").

  `opts` takes one key, and any other raises `ArgumentError` before
  anything is written:

    * `:session` - the host's running `Statifier.Session` (a pid or a
      registered name) for this execution. After the token's upsert has
      committed, the session's registration of this module is replaced
      under the processor's URI and then under `basichttp` with one that
      carries the new token, through `Statifier.Session.replace_send_type/3`.

  With no options it answers exactly as `rotate_location/2`. With
  `session:` it answers:

    * `{:ok, location}` - the new location, and both re-stamps answered
      `:ok`;
    * `{:error, {:no_address, execution_id}}` - no address row names the
      execution; nothing was written and the session was not asked;
    * `{:error, {:session_not_restamped, location, reason}}` - the token
      moved to `location`, and a re-stamp did not: `reason` is the
      engine's refusal (`:not_running`, `:recorded_session`,
      `{:unknown_send_type, type}`, `{:send_types, _}` or
      `{:ioprocessors_entry, _, _}`), or `:replace_send_type_unavailable`
      when the statifier in use does not export the call.

  A session that is not alive, or that does not answer within the
  engine's 5-second timeout, exits the caller after the token has moved.
  """
  @spec rotate_location(Config.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             {:no_address, String.t()}
             | {:session_not_restamped, String.t(), term()}}
  def rotate_location(%Config{basichttp: [_ | _]} = config, execution_id, opts)
      when is_binary(execution_id) and is_list(opts),
      do: rotate_location(config, execution_id, opts, Statifier.Session)

  # The body of rotate_location/3 with the session module as a seam, so a
  # test can hand it a module that does not export replace_send_type/3.
  @doc false
  @spec rotate_location(Config.t(), String.t(), keyword(), module()) ::
          {:ok, String.t()}
          | {:error,
             {:no_address, String.t()}
             | {:session_not_restamped, String.t(), term()}}
  def rotate_location(
        %Config{basichttp: [_ | _] = basichttp} = config,
        execution_id,
        opts,
        session
      )
      when is_binary(execution_id) and is_list(opts) and is_atom(session) do
    opts = Keyword.validate!(opts, [:session])

    case Addresses.by_execution(config, execution_id) do
      nil ->
        {:error, {:no_address, execution_id}}

      %Address{id: address_id} ->
        token = mint_token()

        # The upsert binds the token, so it runs with `log: false`: Ecto's
        # :debug query log would print it (ADR-0002, the Note of 2026-10-02).
        config.repo.insert!(
          Config.put_meta(config, %Location{
            address_id: address_id,
            token: token,
            inserted_at: DateTime.utc_now()
          }),
          on_conflict: [set: [token: token]],
          conflict_target: [:address_id],
          log: false
        )

        location = location_string(Keyword.fetch!(basichttp, :base_url), token)

        case Keyword.fetch(opts, :session) do
          :error -> {:ok, location}
          {:ok, server} -> restamp(session, server, basichttp, token, location)
        end
    end
  end

  # The live session's re-stamp, after the upsert has committed: the
  # registration a create carries, with the new token, under each type
  # string in turn; the first refusal stops it.
  defp restamp(session, server, basichttp, token, location) do
    if Code.ensure_loaded?(session) and function_exported?(session, :replace_send_type, 3) do
      registration = Config.basichttp_registration(basichttp, token)

      Enum.reduce_while(type_strings(), {:ok, location}, fn type, ok ->
        restamp_type(session, server, type, registration, ok)
      end)
    else
      {:error, {:session_not_restamped, location, :replace_send_type_unavailable}}
    end
  end

  defp restamp_type(session, server, type, registration, {:ok, location} = ok) do
    case session.replace_send_type(server, type, registration) do
      :ok -> {:cont, ok}
      {:error, reason} -> {:halt, {:error, {:session_not_restamped, location, reason}}}
    end
  end

  # A fresh token: 32 bytes from the strong generator, unpadded URL-safe
  # base64, derived from nothing.
  @doc false
  @spec mint_token() :: String.t()
  def mint_token, do: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  # Whether `token` has a minted token's shape; one that does not is
  # never looked up.
  @doc false
  @spec token?(term()) :: boolean()
  def token?(token) when is_binary(token), do: Regex.match?(@token_shape, token)
  def token?(_token), do: false

  defp location_string(base_url, token), do: base_url <> "/" <> token
end
