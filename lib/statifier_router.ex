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
    * Execution-to-execution sends: a `<send>` whose `target` is the
      reserved name `StatifierRouter.SendHandler.execution_target/0`
      resolves through the address table and is delivered by the same
      transaction a binding's delivery uses (ADR-0006).
    * The webhook front, `StatifierRouter.Webhook`: a Plug-shaped helper
      a host calls from its own controller or plug.
    * The source invoke: an `<invoke>` whose lifetime is a subscription's,
      through `subscribe/3`, `cancel/2` and the delegate a host's invoke
      handler calls, `StatifierRouter.SourceInvoke` (ADR-0007).

  ## What it does not own

    * Sinks and the route registry.
    * Any queue adapter.
    * Timers: those are `statifier_oban`'s.
    * A publish store: a host callback resolves a document to its active
      chart.
    * Any process or supervisor: the host schedules the reapers and starts
      the pipeline.

  `scope` is an opaque host string; the package gives it no meaning.

  Of the pieces named above, this release builds the Broadway front, as
  `StatifierRouter.Broadway`, and the binding, as
  `StatifierRouter.Binding`. It builds the tables behind the rest,
  created by `StatifierRouter.Migrations` and read through the schemas in
  `StatifierRouter.Schema`. It builds `route/3`, which evaluates the
  bindings for one event and hands each delivery to the configuration's
  delivery module, and that module's default, `StatifierRouter.Delivery`,
  which claims the message for the binding with `StatifierRouter.Dedupe`
  and then, in the same transaction, gets or creates the execution an
  address names and steps the event into it, under each of the three
  `create` modes. It builds `StatifierRouter.Resolver`, the host's answer
  to the chart a new execution starts on, with
  `StatifierRouter.Resolver.Static` over charts compiled at boot. The
  host schedules the two reapers,
  `StatifierRouter.Dedupe.reap/2` and `StatifierRouter.Addresses.reap/2`.
  It builds the source invoke's two calls, `subscribe/3` and `cancel/2`,
  over the subscription table `StatifierRouter.Migrations.V02` adds.
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
  propagates out of `route/3` (ADR-0003, section 1). Neither is a raise
  from writing a key_refused row: a Repo failure there propagates too,
  rather than becoming `{:error, reason}`.

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

  import Ecto.Query, only: [from: 2]

  alias StatifierRouter.Addresses
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.Schema.Subscription

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

  @typedoc """
  One invocation of one execution: the execution's id and the `invoke_id`
  the engine minted for the `<invoke>` (`Statifier.Effect.Invoke`,
  statifier 2.6.0). `invoke_id` is a deterministic `%MachineState{}`
  counter, so it is stable across a replay of the same drive and unique
  within its execution, not across executions.
  """
  @type invocation :: {execution_id :: String.t(), invoke_id :: String.t()}

  @typedoc """
  The identity of one subscription: its binding, its execution and the
  invocation it belongs to (ADR-0007, section 6).
  """
  @type subscription ::
          {binding_id :: String.t(), execution_id :: String.t(), invoke_id :: String.t()}

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
  Subscribes `execution_id`'s invocation `invoke_id` to the binding
  `binding_id`, for as long as the invoking state is entered (ADR-0007,
  sections 2 and 6).

  The subscription reads its `scope` and `key` from the execution's own
  address row, by execution id alone: the invoke names the binding and
  nothing else, because an execution that could name its own key could
  name another execution's (ADR-0007, section 1).

  Returns `{:ok, :subscribed}`, or `{:ok, :already_subscribed}` when a row
  for this `(execution_id, binding_id, invoke_id)` is already there, so a
  handler whose `perform/2` runs twice for one `invoke_id` - which
  `Statifier.Invoke.Handler` says it must tolerate (statifier 2.6.0) -
  writes one row.

  Refuses with:

    * `{:error, {:unknown_binding, binding_id}}` - the configuration has
      no binding under that id, so there is no document to read events
      for.
    * `{:error, {:unaddressed_execution, execution_id}}` - the execution
      has no address row, which is what an `always_new` create leaves
      (ADR-0002, section 7). It has no key to subscribe under, and
      ADR-0007, section 6 refuses the invocation rather than subscribing
      it under an invented one.
  """
  @spec subscribe(Config.t(), String.t(), invocation()) ::
          {:ok, :subscribed | :already_subscribed}
          | {:error, {:unknown_binding | :unaddressed_execution, String.t()}}
  def subscribe(%Config{} = config, binding_id, {execution_id, invoke_id})
      when is_binary(binding_id) and is_binary(execution_id) and is_binary(invoke_id) do
    with :ok <- known_binding(config, binding_id),
         {:ok, address} <- subscribing_address(config, execution_id) do
      row =
        Config.put_meta(config, %Subscription{
          binding_id: binding_id,
          execution_id: execution_id,
          invoke_id: invoke_id,
          scope: address.scope,
          key: address.key,
          inserted_at: DateTime.utc_now()
        })

      case config.repo.insert(row,
             on_conflict: :nothing,
             conflict_target: [:execution_id, :binding_id, :invoke_id]
           ) do
        {:ok, %Subscription{id: nil}} -> {:ok, :already_subscribed}
        {:ok, %Subscription{}} -> {:ok, :subscribed}
      end
    end
  end

  @doc """
  Cancels the subscription named by `{binding_id, execution_id, invoke_id}`,
  deleting the row the matching `subscribe/3` created and nothing else
  (ADR-0007, section 3).

  Returns `{:ok, :cancelled}`, or `{:ok, :not_subscribed}` when no such row
  is there - which is not an error: the engine may plan a cancel for an
  invocation that is already over, and a handler must tolerate cancelling
  an `invoke_id` it no longer knows (`Statifier.Invoke.Handler`'s
  `c:cancel/2`, statifier 2.6.0). Calling it twice is therefore harmless.

  It touches nothing else: not the execution, not its address row, not its
  input log, not its ledger rows, not a delayed send the chart armed, and
  not another binding's subscription for the same execution.

  ## Which `cancel` a host calls

  This package carries three, and they undo three different things:

    * `StatifierRouter.cancel/2`, this one - **the source invoke's**.
      A host calls it when the engine cancels an invocation, which it does
      itself on state exit; `StatifierRouter.SourceInvoke.cancel/3` is the
      delegate that turns a `%Statifier.Effect.CancelInvoke{}` into this
      call, and a host with no source invokes never calls it.
    * `StatifierRouter.SendHandler.cancel/2` - **a delayed send's**. It
      takes a `%Statifier.Effect.Cancel{}` and a scope map, and it is
      reached from the executor seam for spec 6.3's `<cancel sendid>`,
      which the chart author writes. It is not called on state exit: the
      engine cancels no delayed send there (ADR-0007, section 4).
    * `StatifierRouter.TimerQueue.cancel/3` - **a queued timer's**. It is
      a callback on the host's queue adapter, not a function a host calls
      on this package; `SendHandler` calls it.
  """
  @spec cancel(Config.t(), subscription()) :: {:ok, :cancelled | :not_subscribed}
  def cancel(%Config{} = config, {binding_id, execution_id, invoke_id})
      when is_binary(binding_id) and is_binary(execution_id) and is_binary(invoke_id) do
    {count, _} =
      config.repo.delete_all(
        from(s in Config.queryable(config, Subscription),
          where:
            s.execution_id == ^execution_id and s.binding_id == ^binding_id and
              s.invoke_id == ^invoke_id
        )
      )

    if count == 0, do: {:ok, :not_subscribed}, else: {:ok, :cancelled}
  end

  defp known_binding(%Config{bindings: bindings}, binding_id) do
    if Enum.any?(bindings, &(&1.id == binding_id)),
      do: :ok,
      else: {:error, {:unknown_binding, binding_id}}
  end

  defp subscribing_address(config, execution_id) do
    case Addresses.by_execution(config, execution_id) do
      nil -> {:error, {:unaddressed_execution, execution_id}}
      address -> {:ok, address}
    end
  end

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
  @spec refusal_reason(:match | :key, Binding.refusal()) :: refusal_reason()
  defp refusal_reason(program, {:evaluation_error, error}), do: {program, {:error, error}}
  defp refusal_reason(:match, {:non_boolean, value}), do: {:match, {:value, value}}
  defp refusal_reason(:key, {:invalid_key, value}), do: {:key, {:value, value}}

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
