defmodule StatifierRouter.Broadway do
  @moduledoc """
  The Broadway front: a pipeline that hands every message its producer
  emits to `StatifierRouter.route/3`.

  The host starts it in its own supervision tree, with any Broadway
  producer it already operates; this package ships no producer and starts
  no process of its own.

      children = [
        MyApp.Repo,
        {StatifierRouter.Broadway,
         name: MyApp.AdEventsRouter,
         producer: {BroadwayKafka.Producer, kafka_opts},
         router: router_config,
         processors: [default: [concurrency: 8]]}
      ]

  ## Options

  `start_link/1` takes a keyword list:

  | Option | Value | Default |
  |---|---|---|
  | `:name` | the pipeline's name, an atom | required |
  | `:producer` | `{module, opts}`: any Broadway producer and its options | required |
  | `:router` | a `%StatifierRouter.Config{}` | required |
  | `:normalize` | a fun of one `%Broadway.Message{}` returning the event `StatifierRouter.route/3` takes | `normalize/1` |
  | `:processors` | Broadway's `:processors` option, passed through | `[default: []]` |

  Any other key, or a value the table does not allow, raises
  `ArgumentError`, as `Broadway.start_link/2` does for its own options.
  There are no batchers in this release.

  ## Each message

  `handle_message/3` normalizes the message and calls
  `StatifierRouter.route/3`, which returns once every delivery's
  transaction has ended. `{:ok, outcomes}` returns the message unchanged,
  so Broadway acknowledges it after the transactions committed.
  `{:error, reason}` returns it failed with `reason`, so it is not
  acknowledged and the source hands it over again. A raise inside
  `route/3` is not rescued here either: Broadway fails the message it
  raised on, and it is not acknowledged (ADR-0003, section 1).

  ## Partitioning

  `partition/3` is the pipeline's `partition_by`. It keeps every message
  for one address on one processor, so deliveries to one execution reach
  it one after another instead of queueing on its lock, each holding a
  pooled connection while it waits. That is an optimisation and never the
  guarantee: two deliveries to one execution are stepped one at a time by
  statifier_persistence's per-execution lock, whichever processor they
  came through (ADR-0003, section 5). A binding whose `order` is `:none`
  is not partitioned by its key (ADR-0003, section 10).
  """

  use Broadway

  alias Broadway.Message
  alias StatifierRouter.Binding
  alias StatifierRouter.Config

  @known [:name, :producer, :router, :normalize, :processors]

  @doc """
  Starts the pipeline, linked to the calling process. The module
  documentation lists the options.
  """
  @spec start_link(keyword()) :: Broadway.on_start()
  def start_link(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "expected a keyword list of options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @known do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown option #{inspect(key)}"
    end

    router = fetch!(opts, :router, &match?(%Config{}, &1), "a %StatifierRouter.Config{}")
    producer = fetch!(opts, :producer, &producer?/1, "{module, opts}: a Broadway producer")

    normalize =
      opts
      |> Keyword.put_new(:normalize, &normalize/1)
      |> fetch!(:normalize, &is_function(&1, 1), "a fun of one argument")

    Broadway.start_link(__MODULE__,
      name: Keyword.get(opts, :name),
      producer: [module: producer],
      processors: Keyword.get(opts, :processors, default: []),
      partition_by: &partition(&1, router, normalize),
      context: %{router: router, normalize: normalize}
    )
  end

  @doc """
  The default `:normalize`: the event `StatifierRouter.route/3` takes, read
  from the message. `:scope`, `:message_id` and `:source` are read from the
  message's metadata, and the message's data is the event's `data`.

  A message that does not carry all four is not refused here:
  `StatifierRouter.route/3` refuses the event it produces with
  `{:error, {:invalid_event, event}}`, and the message fails. A producer
  whose messages carry them elsewhere is paired with a `:normalize` of the
  host's own.

      iex> message = %Broadway.Message{
      ...>   data: %{"kind" => "click", "impression_id" => "imp_7f3a"},
      ...>   metadata: %{scope: "7c1e", message_id: "ad_events/3/1107", source: "ad_events"},
      ...>   acknowledger: Broadway.NoopAcknowledger.init()
      ...> }
      iex> StatifierRouter.Broadway.normalize(message)
      %{
        scope: "7c1e",
        message_id: "ad_events/3/1107",
        source: "ad_events",
        data: %{"kind" => "click", "impression_id" => "imp_7f3a"}
      }
  """
  @spec normalize(Message.t()) :: map()
  def normalize(%Message{data: data, metadata: metadata}) do
    %{
      scope: Map.get(metadata, :scope),
      message_id: Map.get(metadata, :message_id),
      source: Map.get(metadata, :source),
      data: data
    }
  end

  @doc """
  The partition of one message: the hash, by `:erlang.phash2/1`, of the
  address `{scope, document, key}` of the first binding in `router`'s
  order that is enabled, is for the event's source, has `order: :by_key`,
  and whose `match` holds and `key` produces a key for the event.

  A message no such binding addresses is partitioned by the hash of its
  message id. So is a message `normalize` builds no routable event from,
  one `StatifierRouter.route/3` would refuse: a partitioner answers for
  every message, and `handle_message/3` is where such a message fails.

  `normalize` is called here as well as in `handle_message/3`, and here it
  runs in the producer's dispatcher, where a raise takes the producer down
  with the messages it holds. It is not rescued: a `:normalize` must answer
  for every message, and the default one does.
  """
  @spec partition(Message.t(), Config.t(), (Message.t() -> map())) :: non_neg_integer()
  def partition(%Message{} = message, %Config{} = router, normalize) do
    case normalize.(message) do
      %{scope: scope, source: source, data: data} = event
      when is_binary(scope) and is_binary(source) and is_map(data) ->
        router.bindings
        |> Enum.find_value(&address(&1, event))
        |> case do
          nil -> by_message_id(event)
          address -> :erlang.phash2(address)
        end

      other ->
        by_message_id(other)
    end
  end

  @impl Broadway
  def handle_message(_processor, %Message{} = message, %{router: router, normalize: normalize}) do
    case StatifierRouter.route(router, normalize.(message)) do
      {:ok, _outcomes} -> message
      {:error, reason} -> Message.failed(message, reason)
    end
  end

  defp address(%Binding{enabled: true, order: :by_key, source: source} = binding, %{
         source: source,
         scope: scope,
         data: data
       }) do
    with true <- Binding.match(binding, data),
         {:ok, key} <- Binding.key(binding, data) do
      {scope, binding.document, key}
    else
      _not_addressed -> nil
    end
  end

  defp address(_binding, _event), do: nil

  defp by_message_id(%{message_id: message_id}), do: :erlang.phash2(message_id)
  defp by_message_id(_other), do: :erlang.phash2(nil)

  defp producer?({module, _opts}) when is_atom(module), do: true
  defp producer?(_other), do: false

  defp fetch!(opts, key, valid?, expected) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if valid?.(value) do
          value
        else
          raise ArgumentError,
                "invalid value for #{inspect(key)}: expected #{expected}, got: #{inspect(value)}"
        end

      :error ->
        raise ArgumentError, "missing required option #{inspect(key)}"
    end
  end
end
