defmodule StatifierRouter do
  @moduledoc """
  Routes external events to durable statifier executions, creating them when
  absent.

  The front is Broadway: the host starts `StatifierRouter.Broadway` in its own
  supervision tree with any producer, and `partition_by` keeps every message
  for one key on one processor. Behind it sits a binding, addressing and
  delivery layer over `statifier_persistence`.

  ## What this package owns

    * Bindings: source -> match -> key -> document -> event, with `match` and
      `key` written as predicator programs over the normalized event.
    * The address table: `(scope, document, key)` -> `execution_id`.
    * Atomic get-or-create-and-deliver: the execution an address names is
      created when absent and handed the event in the same step.
    * Dedupe on `(binding, message_id)` with a horizon.
    * The recorded outcome vocabulary: every delivery attempt ends in one
      named outcome.

  ## What it does not own

    * Sinks and the route registry.
    * Execution-to-execution sends.
    * The source invoke.
    * Any queue adapter.
    * The webhook helper.
    * Timers: those are `statifier_oban`'s.
    * A publish store: a host callback resolves a document to its active
      chart.
    * Any process or supervisor: the host schedules the reapers and starts
      the pipeline.

  `scope` is an opaque host string; the package gives it no meaning.

  Of the pieces named above, this release builds the Broadway front, as
  `StatifierRouter.Broadway`; the binding, as `StatifierRouter.Binding`;
  the tables behind the rest, created by
  `StatifierRouter.Migrations` and read through the schemas in
  `StatifierRouter.Schema`; `route/3`, which evaluates the bindings for
  one event and hands each delivery to the configuration's delivery
  module; and that module's default, `StatifierRouter.Delivery`, which
  claims the message for the binding with `StatifierRouter.Dedupe` and
  then, in the same transaction, gets or creates the execution an address
  names and steps the event into it, under each of the three `create`
  modes; and `StatifierRouter.Resolver`, the host's answer to the chart a
  new execution starts on, with `StatifierRouter.Resolver.Static` over
  charts compiled at boot. The host schedules the two reapers,
  `StatifierRouter.Dedupe.reap/2` and `StatifierRouter.Addresses.reap/2`.
  Each piece lands behind the decision record that fixes it, in
  `docs/adr/`.

  ## Routing an event

  `route/3` takes a `StatifierRouter.Config`, the event and options. The
  event carries the host's `scope` beside its message id, its source and
  the adapter-normalized event (ADR-0003, section 8). `route/3` returns one
  outcome per enabled binding whose `source` is the event's source, in the
  order the configuration lists them (ADR-0004, section 6). Bindings are
  chosen by source alone: a binding's `selector` is the source adapter's to
  read, and the router never reads it (ADR-0001, section 1). For each
  binding, the outcome is the first of these that applies (ADR-0004,
  section 2):

    * A `match` that does not hold is `{:no_match, binding_id}`. It writes
      nothing durable (ADR-0004, section 5); it is reported as the
      telemetry event `[:statifier_router, :route, :no_match]`, with the
      measurement `%{count: 1}` and the metadata `binding_id`, `source`,
      `scope` and `message_id`.
    * A `match` that refuses, or a `key` that refuses, is
      `{:key_refused, binding_id, reason}`, with `reason` one of
      `{:match, {:error, error}}`, `{:match, {:value, value}}`,
      `{:key, {:error, error}}` and `{:key, {:value, value}}` (ADR-0004,
      section 1). One row is written to the routing ledger for it, on its
      own (ADR-0004, section 4), and the delivery module is not called.
    * Otherwise the delivery module is called, and its answer is the
      binding's outcome.

  The ledger's `reason` column holds the reason term as `inspect/1`
  renders it with its default options, so `{:key, {:value, :undefined}}`
  is stored as that text. The encoding is for a person reading the
  ledger; nothing parses it back.

  An `{:error, reason}` from the delivery module ends the attempt: the
  bindings after it are not evaluated, `route/3` returns that error, and
  what was already written for the bindings before it stays written
  (ADR-0004, section 7). A raise inside a delivery is not rescued: it
  propagates out of `route/3` (ADR-0003, section 1).

  ## The delivery seam

  The configuration's `:delivery` module is called once for each binding
  whose `key` produced one, as `deliver(config, binding, key, delivery)`,
  where `delivery` is a map of:

    * `:name` - the chart event, the binding's `event`;
    * `:data` - the event's data projected through the binding's `data`
      paths (`StatifierRouter.Binding.project/2`);
    * `:message_id` and `:scope` - the event's own;
    * `:now` - the time this attempt uses for the rows it writes.

  It answers with one of `{:delivered, binding_id, execution_id}`,
  `{:created_and_delivered, binding_id, execution_id}`,
  `{:duplicate, binding_id}`, `{:dropped, binding_id, :no_execution}` and
  `{:dropped, binding_id, :finished}` for the binding it was handed, or
  with `{:error, reason}`, and it writes that outcome's rows inside the
  delivery's own transaction (ADR-0003, section 1). Any other answer
  raises `ArgumentError`. The default module is `StatifierRouter.Delivery`.
  """

  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Ledger

  @version Mix.Project.config()[:version]

  @typedoc """
  The event a host hands `route/3`: the scope it routes under, the message
  id its source adapter derived (a non-empty string, taken as given), the
  source it came from, and the adapter-normalized event as a string-keyed
  map. Other keys are ignored.
  """
  @type source_event :: %{
          required(:scope) => String.t(),
          required(:message_id) => String.t(),
          required(:source) => String.t(),
          required(:data) => map(),
          optional(atom()) => term()
        }

  @typedoc "Which program refused an event for a binding, and how (ADR-0004, section 1)."
  @type refusal_reason ::
          {:match, {:error, term()}}
          | {:match, {:value, term()}}
          | {:key, {:error, term()}}
          | {:key, {:value, term()}}

  @typedoc "One binding's outcome of one routing attempt (ADR-0004, section 1)."
  @type outcome ::
          {:delivered, String.t(), String.t()}
          | {:created_and_delivered, String.t(), String.t()}
          | {:duplicate, String.t()}
          | {:no_match, String.t()}
          | {:key_refused, String.t(), refusal_reason()}
          | {:dropped, String.t(), :no_execution | :finished}

  @typedoc "What the delivery module is handed besides the configuration, binding and key."
  @type delivery :: %{
          name: String.t(),
          data: map(),
          message_id: String.t(),
          scope: String.t(),
          now: DateTime.t()
        }

  @no_match_event [:statifier_router, :route, :no_match]

  @doc """
  Returns this package's version, as `mix.exs` declares it.

      iex> is_binary(StatifierRouter.version())
      true
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Routes one event through the configuration's bindings.

  Returns `{:ok, outcomes}`, one outcome per enabled binding whose `source`
  is the event's source, in configuration order, and `{:ok, []}` when there
  is no such binding. Returns `{:error, reason}` before any binding is
  evaluated for an event whose `message_id` is `nil` or empty
  (`:no_message_id`), for any other malformed event
  (`{:invalid_event, event}`) and for a malformed option
  (`{:invalid_opts, opts}`, `{:unknown_key, name}`,
  `{:invalid_value, :now, value}`), and for the first error the delivery
  module answers with. The module documentation says what each outcome
  writes.

  `opts`:

    * `:now` - a `DateTime` in UTC, the time the attempt uses for the rows
      it and the delivery module write. Defaults to `DateTime.utc_now/0`.
  """
  @spec route(Config.t(), source_event(), keyword()) ::
          {:ok, [outcome()]} | {:error, term()}
  def route(%Config{} = config, source_event, opts \\ []) do
    with {:ok, event} <- validate_event(source_event),
         {:ok, now} <- fetch_now(opts) do
      config.bindings
      |> Enum.filter(&(&1.enabled and &1.source == event.source))
      |> Enum.reduce_while({:ok, []}, &route_next(config, &1, event, now, &2))
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp route_next(config, binding, event, now, {:ok, acc}) do
    case route_binding(config, binding, event, now) do
      {:error, _reason} = error -> {:halt, error}
      outcome -> {:cont, {:ok, [outcome | acc]}}
    end
  end

  # The one mapping from StatifierRouter.Binding's refusal tags to the
  # reason terms of ADR-0004, section 1.
  @doc false
  @spec refusal_reason(:match | :key, Binding.refusal()) :: refusal_reason()
  def refusal_reason(program, {:evaluation_error, error}), do: {program, {:error, error}}
  def refusal_reason(:match, {:non_boolean, value}), do: {:match, {:value, value}}
  def refusal_reason(:key, {:invalid_key, value}), do: {:key, {:value, value}}

  defp validate_event(%{message_id: message_id}) when message_id in [nil, ""],
    do: {:error, :no_message_id}

  defp validate_event(%{scope: scope, message_id: message_id, source: source, data: data} = event)
       when is_binary(scope) and is_binary(message_id) and is_binary(source) and is_map(data),
       do: {:ok, event}

  defp validate_event(other), do: {:error, {:invalid_event, other}}

  defp fetch_now(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_opts, opts}},
         :ok <- Config.reject_unknown(opts, [:now]) do
      case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
        %DateTime{time_zone: "Etc/UTC", microsecond: {usec, _precision}} = now ->
          {:ok, %{now | microsecond: {usec, 6}}}

        other ->
          {:error, {:invalid_value, :now, other}}
      end
    end
  end

  defp route_binding(config, binding, event, now) do
    case Binding.match(binding, event.data) do
      true ->
        key_and_deliver(config, binding, event, now)

      not_for_this_binding when not_for_this_binding in [false, :undefined] ->
        no_match(binding, event)

      {:refused, refusal} ->
        key_refused(config, binding, event, now, refusal_reason(:match, refusal))
    end
  end

  defp key_and_deliver(config, binding, event, now) do
    case Binding.key(binding, event.data) do
      {:ok, key} ->
        deliver(config, binding, key, event, now)

      {:refused, refusal} ->
        key_refused(config, binding, event, now, refusal_reason(:key, refusal))
    end
  end

  defp no_match(%Binding{id: id}, event) do
    :telemetry.execute(@no_match_event, %{count: 1}, %{
      binding_id: id,
      source: event.source,
      scope: event.scope,
      message_id: event.message_id
    })

    {:no_match, id}
  end

  defp key_refused(config, %Binding{id: id}, event, now, reason) do
    row = %Ledger{
      binding_id: id,
      message_id: event.message_id,
      scope: event.scope,
      outcome: "key_refused",
      key: nil,
      execution_id: nil,
      reason: inspect(reason),
      inserted_at: now
    }

    config.repo.insert!(Config.put_meta(config, row))
    {:key_refused, id, reason}
  end

  defp deliver(config, %Binding{id: id} = binding, key, event, now) do
    delivery = %{
      name: binding.event,
      data: Binding.project(binding, event.data),
      message_id: event.message_id,
      scope: event.scope,
      now: now
    }

    config.delivery.deliver(config, binding, key, delivery)
    |> check_answer(config.delivery, id)
  end

  defp check_answer({:delivered, id, execution_id} = outcome, _module, id)
       when is_binary(execution_id),
       do: outcome

  defp check_answer({:created_and_delivered, id, execution_id} = outcome, _module, id)
       when is_binary(execution_id),
       do: outcome

  defp check_answer({:duplicate, id} = outcome, _module, id), do: outcome

  defp check_answer({:dropped, id, why} = outcome, _module, id)
       when why in [:no_execution, :finished],
       do: outcome

  defp check_answer({:error, _reason} = error, _module, _id), do: error

  defp check_answer(other, module, id) do
    raise ArgumentError,
          "#{inspect(module)}.deliver/4 answered #{inspect(other)} for the binding " <>
            "#{inspect(id)}; expected one of the delivery outcomes for that binding, " <>
            "or {:error, reason}"
  end
end
