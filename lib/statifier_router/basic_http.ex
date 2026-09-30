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
  TLS, and rotate it with `rotate_location/2` when it may have leaked.

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
  answered 404 by the front. Rotation does not reach the execution's own
  `_ioprocessors`: statifier writes that entry once, when the execution
  starts, so after a rotation the chart still reads the location it
  started with, which no longer answers. A host that rotates hands the new
  location to whoever should hold it. Both functions build the location
  from the configuration's current base URL.

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
  def rotate_location(%Config{basichttp: [_ | _] = basichttp} = config, execution_id)
      when is_binary(execution_id) do
    case Addresses.by_execution(config, execution_id) do
      nil ->
        {:error, {:no_address, execution_id}}

      %Address{id: address_id} ->
        token = mint_token()

        config.repo.insert!(
          Config.put_meta(config, %Location{
            address_id: address_id,
            token: token,
            inserted_at: DateTime.utc_now()
          }),
          on_conflict: [set: [token: token]],
          conflict_target: [:address_id]
        )

        {:ok, location_string(Keyword.fetch!(basichttp, :base_url), token)}
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
