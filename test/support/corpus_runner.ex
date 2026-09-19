defmodule StatifierRouter.CorpusRunner do
  @moduledoc """
  Runs one case of the corpus under `corpus/` against the real delivery:
  `StatifierRouter.route/3` over `StatifierRouter.Delivery`, with
  statifier_persistence's executions in this suite's Postgres database.
  `corpus/README.md` describes the case format. Test-only support code, not
  part of the package's public API.

  The case's bindings are built with `StatifierRouter.Binding.new/1`, and
  the chart a document names is `corpus/charts/<document>.scxml`, compiled
  by statifier and resolved under the case's scope by
  `StatifierRouter.Resolver.Static`. Each `deliver` step is one call to
  `route/3`.

  The runner plays the host's part for timers. statifier hands a delayed
  send to the host as a `:send_delayed` effect and a `<cancel>` as a
  `:cancel` effect, and the executor here records both. The runner keeps
  its own clock, which starts at `start/0` and moves only on an `advance`
  step: every recorded send whose delay has elapsed by then is fired, in
  the order it falls due, by stepping its event into its execution with
  `StatifierPersistence.Executions.step/5` and the chart the
  configuration's chart resolver answers for the execution. A send is
  fired at the time it fell due, so a send it schedules in turn is timed
  from there. A cancel removes the execution's recorded sends that carry
  its send id.

  `run/1` answers with what the case's `expected` object compares against,
  in the same shape.
  """

  import Ecto.Query, only: [from: 2]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias Statifier.Event
  alias Statifier.Machine
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Config
  alias StatifierRouter.Resolver
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @corpus Path.expand("../../corpus", __DIR__)
  @start ~U[2026-09-19 08:00:00.000000Z]

  # The binding keys a case may carry, and the enumerated values of the
  # two keys whose values Binding.new/1 takes as atoms. Everything else in
  # a case is a string, a number, a list or an object.
  @binding_keys ~w(id source selector match key document event data create order enabled)
  @enumerated %{
    "create" => ~w(if_absent never always_new),
    "order" => ~w(by_key none)
  }

  @doc "The corpus directory."
  @spec corpus() :: Path.t()
  def corpus, do: @corpus

  @doc "Every case file under `corpus/cases/`, sorted by name."
  @spec case_paths() :: [Path.t()]
  def case_paths, do: @corpus |> Path.join("cases/*.json") |> Path.wildcard() |> Enum.sort()

  @doc "Every chart file under `corpus/charts/`, sorted by name."
  @spec chart_paths() :: [Path.t()]
  def chart_paths, do: @corpus |> Path.join("charts/*.scxml") |> Path.wildcard() |> Enum.sort()

  @doc "Reads and decodes one case file."
  @spec load!(Path.t()) :: map()
  def load!(path), do: path |> File.read!() |> JSON.decode!()

  @doc "The time the runner's clock starts at."
  @spec start() :: DateTime.t()
  def start, do: @start

  @doc """
  Runs `kase` and answers with the ledger rows for its bindings, the active
  configuration of its one execution and the datamodel keys its
  `expected.datamodel` names, shaped as `expected` is.

  Raises when a step fails, when the case's scope and document address
  anything but exactly one execution, or when a ledger row names another
  execution.
  """
  @spec run(map()) :: map()
  def run(%{"scope" => scope, "document" => document, "script" => script} = kase) do
    runner = self()
    config = config(kase, runner)

    state =
      Enum.reduce(script, %{clock: @start, pending: []}, fn step, state ->
        run_step(step, state, config, scope)
      end)

    [execution_id] =
      TestRepo.all(
        from(a in Config.queryable(config, Address),
          where: a.scope == ^scope and a.document == ^document,
          select: a.execution_id
        )
      )

    %{
      "ledger" => ledger(config, kase, execution_id),
      "status" => status(config, execution_id),
      "configuration" => configuration(config, execution_id),
      "datamodel" => datamodel(config, execution_id, kase),
      "timers" => state.pending |> Enum.map(& &1.effect.event) |> Enum.sort()
    }
    |> Map.take(Map.keys(kase["expected"]))
  end

  # -- the script -----------------------------------------------------------

  defp run_step(%{"deliver" => deliver}, state, config, scope) do
    event = %{
      scope: scope,
      message_id: Map.fetch!(deliver, "message_id"),
      source: Map.fetch!(deliver, "source"),
      data: Map.fetch!(deliver, "data")
    }

    {:ok, _outcomes} = StatifierRouter.route(config, event, now: state.clock)
    record_effects(state)
  end

  defp run_step(%{"advance" => iso8601}, state, config, _scope) do
    until = DateTime.shift(state.clock, Duration.from_iso8601!(iso8601))
    state |> fire_due(until, config) |> Map.put(:clock, until)
  end

  # Fires the earliest recorded send that is due by `until`, then looks
  # again: a fired send may schedule one that is also due by then.
  defp fire_due(state, until, config) do
    due = Enum.filter(state.pending, &(DateTime.compare(&1.due, until) != :gt))

    case Enum.sort_by(due, &{DateTime.to_unix(&1.due, :microsecond), &1.effect.ordinal}) do
      [] ->
        state

      [send | _later] ->
        state = %{state | clock: send.due, pending: List.delete(state.pending, send)}
        fire(send, config)
        state |> record_effects() |> fire_due(until, config)
    end
  end

  defp fire(%{effect: %SendDelayed{} = effect} = send, config) do
    {:ok, machine} = config.chart_resolver.(send.content_hash)

    event =
      Event.external(effect.event,
        data: effect.data,
        sendid: if(effect.id_from_author?, do: effect.send_id)
      )

    case Executions.step(config.store, send.execution_id, machine, event,
           executor: config.executor
         ) do
      {:ok, _execution, _machine_state} -> :ok
      {:discarded, _execution} -> :ok
    end
  end

  # The executor ran in this process, so every effect it recorded since the
  # last look is a message here, in the order it was handed the effects.
  defp record_effects(state) do
    receive do
      {__MODULE__, {:send_delayed, %SendDelayed{} = effect}, context} ->
        send = %{
          due: DateTime.add(state.clock, effect.delay_ms, :millisecond),
          effect: effect,
          execution_id: context.execution_id,
          content_hash: context.content_hash
        }

        record_effects(%{state | pending: state.pending ++ [send]})

      {__MODULE__, {:cancel, %Cancel{send_id: send_id}}, context} ->
        pending =
          Enum.reject(state.pending, fn send ->
            send.execution_id == context.execution_id and send.effect.send_id == send_id
          end)

        record_effects(%{state | pending: pending})

      {__MODULE__, _other_effect, _context} ->
        record_effects(state)
    after
      0 -> state
    end
  end

  # -- the configuration ----------------------------------------------------

  defp config(%{"scope" => scope, "bindings" => bindings}, runner) do
    machines = machines()
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)
    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})

    {:ok, resolver} =
      machines
      |> Map.new(fn {document, machine} -> {{scope, document}, machine} end)
      |> Resolver.Static.new()

    executor = fn effect, context ->
      send(runner, {__MODULE__, effect, context})
      :ok
    end

    {:ok, config} =
      Config.new(
        repo: TestRepo,
        store: store,
        executor: executor,
        resolver: resolver,
        chart_resolver: &Map.fetch(by_hash, &1),
        bindings: Enum.map(bindings, &binding_attrs/1)
      )

    config
  end

  defp machines do
    Map.new(chart_paths(), fn path ->
      {:ok, machine} = path |> File.read!() |> Statifier.compile()
      {Path.basename(path, ".scxml"), machine}
    end)
  end

  defp binding_attrs(binding) do
    Map.new(binding, fn {name, value} when name in @binding_keys ->
      {String.to_existing_atom(name), binding_value(name, value)}
    end)
  end

  defp binding_value(name, value) when is_map_key(@enumerated, name) do
    if value in Map.fetch!(@enumerated, name),
      do: String.to_existing_atom(value),
      else: raise(ArgumentError, "#{name} cannot be #{inspect(value)} in a corpus case")
  end

  defp binding_value(_name, value), do: value

  # -- what the case compares -----------------------------------------------

  defp ledger(config, %{"bindings" => bindings}, execution_id) do
    ids = Enum.map(bindings, & &1["id"])

    from(l in Config.queryable(config, Ledger), where: l.binding_id in ^ids, order_by: l.id)
    |> TestRepo.all()
    |> Enum.map(fn %Ledger{} = row ->
      if row.execution_id not in [nil, execution_id] do
        raise "the ledger row #{inspect(row)} names another execution than #{execution_id}"
      end

      %{
        "binding" => row.binding_id,
        "message_id" => row.message_id,
        "outcome" => row.outcome,
        "key" => row.key
      }
    end)
  end

  defp status(config, execution_id) do
    {:ok, record} = Storage.fetch_execution(config.store, execution_id)
    Atom.to_string(record.status)
  end

  defp configuration(config, execution_id) do
    {:ok, machine_state} = position(config, execution_id)
    machine_state |> Statifier.active_leaf_states() |> Enum.sort()
  end

  defp datamodel(config, execution_id, %{"expected" => expected}) do
    {:ok, machine_state} = position(config, execution_id)
    Map.take(machine_state.datamodel, Map.keys(Map.get(expected, "datamodel", %{})))
  end

  defp position(config, execution_id) do
    {:ok, record} = Storage.fetch_execution(config.store, execution_id)
    {:ok, machine} = config.chart_resolver.(record.content_hash)
    Storage.load_execution_position(config.store, execution_id, machine)
  end
end
