defmodule StatifierRouter.Webhook do
  @moduledoc """
  The webhook front: a Plug-shaped helper that turns one already-verified
  webhook request into a routing attempt. **This package verifies nothing.**
  The host authenticates the request - typically a provider's signature over
  the raw body - and calls `handle/3` only after that verification has
  passed. A request that reaches this module is one the host has already
  vouched for.

  It is Plug-shaped, not a Plug: it adds no dependency on Plug or Phoenix,
  and starts no process. The host writes the controller action or the plug
  and calls `handle/3` from it; the README's "A webhook front" section shows
  the ten lines that takes.

  ## The request

  `handle/3` takes a plain map the host builds from the connection:

    * `:scope` - the host's routing scope, a string, as it rides with every
      event (ADR-0003, section 8);
    * `:source` - the source the bindings name;
    * `:raw_body` - the request body exactly as it arrived, the bytes whose
      signature was verified;
    * `:data` - the adapter-normalized event, a string-keyed map;
    * `:provider_id` - the provider's own event id, or `nil`;
    * `:selector` - the source's selector, carried for the host's own front
      and **never read here**. A binding's `selector` is the source
      adapter's to read, and the router never reads it (ADR-0001,
      section 1); bindings are chosen by source alone.

  Any other key is ignored. A request missing `:scope`, `:source`,
  `:raw_body` or `:data`, or carrying one of the wrong type, is
  `{:error, {:invalid_request, request}}` and nothing is routed.

  ## The message id

  The message id is the dedupe key downstream, so which source wins is
  fixed here rather than left to each host (ADR-0003, section 6):

    * the provider's `:provider_id` wins whenever it is a **non-empty
      string**;
    * otherwise - `nil`, `""`, or any non-string - the message id is the
      lowercase hex SHA-256 of `:raw_body`.

  A provider that sends no event id therefore gets one delivery per
  distinct body, and its retry of the same body is the same message. There
  is no third source: `:raw_body` is required, so an id is always derivable,
  and the SHA-256 of an empty body is a well-defined, constant id rather
  than a failure.

  ## The answer and the status

  `handle/3` answers exactly as `StatifierRouter.route/3` does,
  `{:ok, outcomes}` or `{:error, reason}`, and `status/1` maps that answer
  to the HTTP status the provider should see.
  """

  alias StatifierRouter.Config

  @typedoc """
  The request a host hands `handle/3` once it has verified the signature.
  The module documentation describes each key.
  """
  @type request :: %{
          required(:scope) => String.t(),
          required(:source) => String.t(),
          required(:raw_body) => binary(),
          required(:data) => map(),
          optional(:provider_id) => String.t() | nil,
          optional(:selector) => map(),
          optional(atom()) => term()
        }

  @typedoc "What `handle/3` answers, and what `status/1` reads."
  @type answer :: {:ok, [StatifierRouter.outcome()]} | {:error, term()}

  @doc """
  Routes one verified webhook request.

  Derives the message id as the module documentation describes, builds the
  source event `StatifierRouter.route/3` takes and returns that function's
  answer unchanged: `{:ok, outcomes}`, one outcome per enabled binding
  whose `source` is the request's, or `{:error, reason}`.

  Returns `{:error, {:invalid_request, request}}`, before any binding is
  evaluated, for a request this module cannot build an event from.

  `opts` are `StatifierRouter.route/3`'s and are passed through unchanged,
  so an unknown key is that function's error.
  """
  @spec handle(Config.t(), request(), keyword()) :: answer()
  def handle(config, request, opts \\ [])

  def handle(%Config{} = config, request, opts) when is_map(request) and is_list(opts) do
    case source_event(request) do
      {:ok, event} -> StatifierRouter.route(config, event, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The HTTP status the provider should see for one `handle/3` answer.

  `{:ok, outcomes}` is `200`, whatever those outcomes are. Every one of
  them is a recorded answer this router will give again for the same
  message - a duplicate, a drop, a refusal and a no-match included - so a
  retry would change nothing and the provider should stop.

  `{:error, reason}` is `500`: the attempt did not settle, so the provider
  should retry.

      iex> StatifierRouter.Webhook.status({:ok, [{:duplicate, "clicks_to_join"}]})
      200

      iex> StatifierRouter.Webhook.status({:error, :no_message_id})
      500
  """
  @spec status(answer()) :: 200 | 500
  def status({:ok, outcomes}) when is_list(outcomes), do: 200
  def status({:error, _reason}), do: 500

  defp source_event(%{scope: scope, source: source, raw_body: raw_body, data: data} = request)
       when is_binary(scope) and is_binary(source) and is_binary(raw_body) and is_map(data) do
    {:ok,
     %{
       scope: scope,
       message_id: message_id(Map.get(request, :provider_id), raw_body),
       source: source,
       data: data
     }}
  end

  defp source_event(request), do: {:error, {:invalid_request, request}}

  defp message_id(provider_id, _raw_body) when is_binary(provider_id) and provider_id != "",
    do: provider_id

  defp message_id(_absent, raw_body),
    do: Base.encode16(:crypto.hash(:sha256, raw_body), case: :lower)
end
