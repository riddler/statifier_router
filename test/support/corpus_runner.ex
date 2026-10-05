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

  `run/2` with `timers: :oban` plays that part a second way: through
  statifier_oban on the Oban instance `StatifierRouter.TestOban` in this
  suite's Postgres database, rather than through the runner's own list.
  A delayed send is scheduled with `StatifierOban.Timer.schedule/3` under
  its execution's id, and the job's fire time is then moved off the wall
  clock onto the runner's clock: the time the send was handed over on
  that clock, plus its delay. Before it moves the fire time, the runner
  asserts that the one statifier_oban stored is the wall clock at the
  hand-over plus the send's delay, so a fault in statifier_oban's own
  delay arithmetic fails the case rather than being written over. A
  cancel is `StatifierOban.Timer.cancel/3` under the same id. On an
  advance the runner drains the timers queue one job at a time, the
  earliest due first, each at the time it falls due, so a job a fired
  send cancels is off the queue before the queue is read again. The fired
  job reaches its execution through `StatifierRouter.CorpusTimerDelivery`,
  a process-less host's `StatifierOban.Timer.Delivery`. The pending
  timers a case compares are then the jobs still waiting on the queue, in
  the states statifier_oban itself counts as a timer that has not fired:
  `suspended`, `scheduled`, `available` and `retryable`. A drain fires
  only the last three, so a suspended job stays pending and is never
  fired.

  The runner also plays the host's part for sinks. A case's `routes` names
  the routes it registers; each is registered as
  `StatifierRouter.RecordingRoute` reporting to the runner's own process,
  and the runner's executor hands every effect to
  `StatifierRouter.SendHandler`, so a chart's `<send>` of `send_type/0`
  reaches its route through the package's own handler. Every send a route
  was handed is collected in order and compared as `expected.sends`. A
  case that registers routes and states no `expected.sends` is raised on
  rather than run: a member left out would otherwise be a comparison that
  cannot fail.

  A case whose `expected` holds `contracts` is a publish case instead: it
  runs no script and delivers nothing. The runner builds the same
  configuration, takes the chart its `document` names, and answers with
  `StatifierRouter.Contracts.check/3` over the two, under the host's
  lookup built from the case's `declarations`: a document the map names
  declares those event names, a document it leaves out that has a chart
  under `corpus/charts/` declares nothing and is judged by that chart's
  computed vocabulary, and any other document is not published. The
  report is written the way a case writes it: keys and reasons as
  strings, and each location as its start `line` and `column`.

  `run/1` answers with what the case's `expected` object compares against,
  in the same shape.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions, only: [assert: 2]

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias Statifier.Event
  alias Statifier.Machine
  alias Statifier.Parser.Location
  alias StatifierOban.Timer
  alias StatifierOban.Timer.JobArgs
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Addresses
  alias StatifierRouter.Config
  alias StatifierRouter.Contracts
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.Resolver
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @corpus Path.expand("../../corpus", __DIR__)
  @start ~U[2026-09-19 08:00:00.000000Z]
  @send_type "myapp:sink"
  @config_key {__MODULE__, :config}

  # The Oban run mode: the instance test/test_helper.exs starts, the queue
  # the runner's timers go to, and the states a job that has not fired can
  # be in. The pending states are statifier_oban's own (the set
  # `StatifierOban.Timer.pending_for/2` counts and `cancel/3` reaches),
  # `suspended` among them: a held job has not fired. The drainable states
  # are the ones `Oban.drain_queue/2` fires, which leave `suspended` out;
  # the look for the next job due reads those, or it would pick a job no
  # drain fires.
  @oban StatifierRouter.TestOban
  @timers_queue :corpus_timers
  @pending_states ~w(suspended scheduled available retryable)
  @drainable_states @pending_states -- ~w(suspended)

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

  @doc """
  Every delivery case file under `corpus/cases/`, sorted by name: every
  case but a publish case, which runs no script and so no timer.
  """
  @spec delivery_case_paths() :: [Path.t()]
  def delivery_case_paths,
    do: Enum.reject(case_paths(), &Map.has_key?(load!(&1)["expected"], "contracts"))

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
  The `type` the corpus's charts write on an outbound send, and the type
  the runner registers as the host's. A `<send>` of any other type is not
  this handler's and reaches no route.
  """
  @spec send_type() :: String.t()
  def send_type, do: @send_type

  @doc "Every route name any case registers, sorted."
  @spec route_names() :: [String.t()]
  def route_names do
    case_paths()
    |> Enum.flat_map(&Map.get(load!(&1), "routes", []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Runs `kase` and answers with the ledger rows for its bindings, the sends
  its routes were handed, the active configuration of its one execution
  and the datamodel keys its `expected.datamodel` names, shaped as
  `expected` is.

  Raises when a step fails, when the case registers routes and states no
  `expected.sends`, when the case's scope and document address more than
  one execution or never address one, or when a ledger row names another
  execution.

  A publish case, one whose `expected` holds `contracts`, answers with
  `contracts` alone, and raises when it carries a non-empty `script`: a
  step it would not run is a step the case could not check.

  `opts` takes `timers:`, either `:memory` (the default), which keeps the
  case's timers in the runner's own list, or `:oban`, which schedules,
  cancels and fires them through statifier_oban on an Oban queue, as the
  moduledoc says. A publish case takes no timer either way.
  """
  @spec run(map(), keyword()) :: map()
  def run(kase, opts \\ [])

  def run(%{"expected" => %{"contracts" => _contracts}} = kase, _opts) do
    if Map.get(kase, "script", []) != [] do
      raise ArgumentError,
            "the case #{kase["id"]} expects contracts, runs no script and carries one"
    end

    config = config(kase, self())
    machines = machines()
    machine = Map.fetch!(machines, kase["document"])
    lookup = lookup(Map.get(kase, "declarations", %{}), machines)

    %{"contracts" => config |> Contracts.check(machine, lookup) |> case_terms()}
  end

  def run(%{"scope" => scope, "document" => document, "script" => script} = kase, opts) do
    runner = self()
    expects_sends!(kase)
    config = config(kase, runner)

    initial = %{
      clock: @start,
      timers: timers(Keyword.get(opts, :timers, :memory)),
      pending: [],
      sends: [],
      execution_id: nil
    }

    state =
      Enum.reduce(script, initial, fn step, state ->
        step |> run_step(state, config, kase) |> address(config, scope, document)
      end)

    execution_id =
      state.execution_id ||
        raise "the case #{kase["id"]} addressed no execution under #{scope}/#{document}"

    %{
      "ledger" => ledger(config, kase, execution_id),
      "status" => status(config, execution_id),
      "configuration" => configuration(config, execution_id),
      "datamodel" => datamodel(config, execution_id, kase),
      "timers" => pending_timers(state),
      "sends" => state.sends
    }
    |> Map.take(Map.keys(kase["expected"]))
  end

  # A case that registers routes states what its routes were handed. Left
  # out, `Map.take/2` below would drop the member and the case would pass
  # whatever the chart sent, which is an assertion that cannot fail.
  defp expects_sends!(kase) do
    routes = Map.get(kase, "routes", [])
    expected = Map.get(kase, "expected", %{})

    if routes != [] and not Map.has_key?(expected, "sends") do
      raise ArgumentError,
            "the case #{kase["id"]} registers the routes #{Enum.join(routes, ", ")} " <>
              "and states no expected sends"
    end

    :ok
  end

  # The execution the case's scope and document address, kept as the
  # script runs: an address row can be reaped before the case ends, and
  # the execution it named is still what the case compares.
  defp address(state, config, scope, document) do
    query =
      from(a in Config.queryable(config, Address),
        where: a.scope == ^scope and a.document == ^document,
        select: a.execution_id
      )

    case TestRepo.all(query) do
      [] -> state
      [execution_id] -> %{state | execution_id: execution_id}
      many -> raise "#{scope}/#{document} addresses more than one execution: #{inspect(many)}"
    end
  end

  # -- the script -----------------------------------------------------------

  defp run_step(%{"deliver" => deliver}, state, config, %{"scope" => scope}) do
    event = %{
      scope: scope,
      message_id: Map.fetch!(deliver, "message_id"),
      source: Map.fetch!(deliver, "source"),
      data: Map.fetch!(deliver, "data")
    }

    {:ok, _outcomes} = StatifierRouter.route(config, event, now: state.clock)
    record_effects(state)
  end

  defp run_step(%{"advance" => iso8601}, state, config, _kase) do
    until = DateTime.shift(state.clock, Duration.from_iso8601!(iso8601))
    state |> fire_due(until, config) |> Map.put(:clock, until)
  end

  # One run of `StatifierRouter.Addresses.reap/3` at the case's clock. The
  # reaper stamps a terminal row the first time it reads it and deletes it
  # once that row's horizon has passed, so a case reaps twice around an
  # advance to see a row gone.
  defp run_step(%{"reap" => "addresses"}, state, config, _kase) do
    {:ok, _result} = Addresses.reap(config, config.bindings, now: state.clock)
    state
  end

  # Fires the earliest recorded send that is due by `until`, then looks
  # again: a fired send may schedule one that is also due by then.
  defp fire_due(%{timers: :memory} = state, until, config) do
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

  # The Oban run mode: drains the one job that falls due first by `until`,
  # at the time it falls due, then looks again. One job a drain, so a job
  # the fired one cancels is off the queue before the next drain reads it.
  # A delivery that raises is raised here (`with_safety: false`) rather
  # than left on the queue as a retry the case would not see.
  defp fire_due(%{timers: %StatifierOban.Config{} = timers} = state, until, config) do
    case next_due(until) do
      nil ->
        state

      due ->
        %{success: fired, cancelled: discarded} =
          Oban.drain_queue(timers.oban,
            queue: timers.timers_queue,
            with_scheduled: due,
            with_limit: 1,
            with_safety: false
          )

        1 = fired + discarded
        %{state | clock: due} |> record_effects() |> fire_due(until, config)
    end
  end

  defp next_due(until) do
    from(j in Oban.Job,
      where:
        j.queue == ^Atom.to_string(@timers_queue) and j.state in ^@drainable_states and
          j.scheduled_at <= ^until,
      order_by: [asc: j.scheduled_at, asc: j.id],
      limit: 1,
      select: j.scheduled_at
    )
    |> TestRepo.one()
  end

  defp fire(%{effect: %SendDelayed{} = effect} = send, config) do
    event =
      Event.external(effect.event,
        data: effect.data,
        sendid: if(effect.id_from_author?, do: effect.send_id)
      )

    {_answer, _execution} = step_fired(config, send.execution_id, send.content_hash, event)
    :ok
  end

  @doc """
  Steps a fired timer's `event` into the execution `execution_id`, on the
  chart the configuration's chart resolver answers for `content_hash`.
  Answers `{:ok, execution}` when the execution took the event, and
  `{:discarded, execution}` when it is no longer active and did not. Both
  run modes fire through it; the Oban one reaches it through
  `StatifierRouter.CorpusTimerDelivery`.
  """
  @spec step_fired(Config.t(), String.t(), String.t(), Event.t()) ::
          {:ok | :discarded, StatifierPersistence.Execution.t()}
  def step_fired(config, execution_id, content_hash, event) do
    {:ok, machine} = config.chart_resolver.(content_hash)

    # The snapshot options travel on every step, top level, the way
    # `StatifierRouter.Delivery` sends them: a timer-fired step that
    # carried only the executor would leave `:send_types` unregistered,
    # and a `<send>` of `send_type/0` the fired event reaches would not be
    # a registered type on that step alone.
    opts = [{:executor, config.executor} | config.persistence_options]

    case Executions.step(config.store, execution_id, machine, event, opts) do
      {:ok, execution, _machine_state} -> {:ok, execution}
      {:discarded, execution} -> {:discarded, execution}
    end
  end

  @doc """
  The configuration of the case running in this process. A timer the Oban
  run mode fires is drained in the same process, and steps with it.
  """
  @spec current_config() :: Config.t()
  def current_config, do: Process.get(@config_key) || raise("no corpus case is running here")

  # The executor ran in this process, so every effect it recorded since the
  # last look is a message here, in the order it was handed the effects.
  defp record_effects(state) do
    receive do
      {__MODULE__, {:send_delayed, %SendDelayed{} = effect}, context} ->
        state |> schedule(effect, context) |> record_effects()

      {__MODULE__, {:cancel, %Cancel{} = effect}, context} ->
        state |> cancel(effect, context) |> record_effects()

      {__MODULE__, _other_effect, _context} ->
        record_effects(state)

      {:routed, %{sink: route}, %Event{} = event, _key} ->
        send = %{"route" => route, "event" => %{"name" => event.name, "data" => event.data}}
        record_effects(%{state | sends: state.sends ++ [send]})
    after
      0 -> state
    end
  end

  # -- the timers -----------------------------------------------------------

  defp timers(:memory), do: :memory

  defp timers(:oban) do
    {:ok, timers} =
      StatifierOban.Config.new(
        oban: @oban,
        timers_queue: @timers_queue,
        delivery: StatifierRouter.CorpusTimerDelivery
      )

    timers
  end

  defp schedule(%{timers: :memory} = state, effect, context) do
    send = %{
      due: DateTime.add(state.clock, effect.delay_ms, :millisecond),
      effect: effect,
      execution_id: context.execution_id,
      content_hash: context.content_hash
    }

    %{state | pending: state.pending ++ [send]}
  end

  # statifier_oban times the job off the wall clock; the runner moves it
  # onto its own, so the job falls due when the case's clock says so.
  # First it checks the time statifier_oban stored: the wall clock read on
  # either side of the hand-over brackets it, each plus the delay.
  defp schedule(%{timers: %StatifierOban.Config{} = timers} = state, effect, context) do
    handed_over = DateTime.utc_now()

    {:ok, %Oban.Job{conflict?: false, id: id}} =
      Timer.schedule(timers, context.execution_id, effect)

    returned = DateTime.utc_now()
    job = from(j in Oban.Job, where: j.id == ^id)
    stored = TestRepo.one!(from(j in job, select: j.scheduled_at))
    assert_computed_due(stored, handed_over, returned, effect)

    due = DateTime.add(state.clock, effect.delay_ms, :millisecond)
    {1, _rows} = TestRepo.update_all(job, set: [scheduled_at: due])
    state
  end

  defp assert_computed_due(stored, handed_over, returned, effect) do
    earliest = DateTime.add(handed_over, effect.delay_ms, :millisecond)
    latest = DateTime.add(returned, effect.delay_ms, :millisecond)

    assert DateTime.compare(stored, earliest) != :lt and
             DateTime.compare(stored, latest) != :gt,
           "statifier_oban scheduled the send #{inspect(effect.event)} " <>
             "(delay #{effect.delay_ms}ms) at #{DateTime.to_iso8601(stored)}, " <>
             "outside the wall clock at its hand-over plus the delay: " <>
             "#{DateTime.to_iso8601(earliest)} to #{DateTime.to_iso8601(latest)}"
  end

  defp cancel(%{timers: :memory} = state, %Cancel{send_id: send_id}, context) do
    pending =
      Enum.reject(state.pending, fn send ->
        send.execution_id == context.execution_id and send.effect.send_id == send_id
      end)

    %{state | pending: pending}
  end

  defp cancel(%{timers: %StatifierOban.Config{} = timers} = state, effect, context) do
    {:ok, _cancelled} = Timer.cancel(timers, context.execution_id, effect)
    state
  end

  defp pending_timers(%{timers: :memory, pending: pending}),
    do: pending |> Enum.map(& &1.effect.event) |> Enum.sort()

  defp pending_timers(%{timers: %StatifierOban.Config{}}) do
    from(j in Oban.Job,
      where: j.queue == ^Atom.to_string(@timers_queue) and j.state in ^@pending_states,
      select: j.args
    )
    |> TestRepo.all()
    |> Enum.map(fn args ->
      {:ok, _execution_id, effect} = JobArgs.to_effect(args)
      effect.event
    end)
    |> Enum.sort()
  end

  # -- the configuration ----------------------------------------------------

  defp config(%{"scope" => scope, "bindings" => bindings} = kase, runner) do
    machines = machines()
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)
    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})

    {:ok, resolver} =
      machines
      |> Map.new(fn {document, machine} -> {{scope, document}, machine} end)
      |> Resolver.Static.new()

    # The runner reads the timers off every effect, and the package's own
    # handler takes the sends: a `<send>` of `send_type/0` is handed to
    # the route its `target` names, and anything else is ignored there.
    # The configuration the handler needs is the one being built, so it is
    # read back from this process rather than closed over.
    executor = fn effect, context ->
      send(runner, {__MODULE__, effect, context})
      SendHandler.handle_effect(Process.get(@config_key), effect, context)
    end

    {:ok, config} =
      Config.new(
        repo: TestRepo,
        store: store,
        executor: executor,
        resolver: resolver,
        chart_resolver: &Map.fetch(by_hash, &1),
        send_type: @send_type,
        route_adapters: route_adapters(kase, runner),
        bindings: Enum.map(bindings, &binding_attrs/1)
      )

    Process.put(@config_key, config)
    config
  end

  # Every route the case registers, served by the recording adapter, which
  # reports to the runner's process and hands nothing anywhere.
  defp route_adapters(kase, runner) do
    kase
    |> Map.get("routes", [])
    |> Map.new(&{&1, {RecordingRoute, %{pid: runner, sink: &1}}})
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

  # -- a publish case -------------------------------------------------------

  # The host's lookup (ADR-0008, decision 2) over the corpus: a document
  # the case's `declarations` names declares those names; one it leaves
  # out declares nothing when the corpus has its chart, and is otherwise
  # not published.
  defp lookup(declarations, machines) do
    fn document ->
      case {Map.fetch(declarations, document), Map.fetch(machines, document)} do
        {{:ok, names}, _chart} -> {:ok, names}
        {:error, {:ok, machine}} -> {:ok, :undeclared, machine}
        {:error, :error} -> {:error, :not_published}
      end
    end
  end

  # `Contracts.check/3`'s report as a case writes it: string keys, atoms
  # as strings, and a location as its start line and column.
  defp case_terms(%Location{start_line: line, start_column: column}),
    do: %{"line" => line, "column" => column}

  defp case_terms(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), case_terms(value)} end)

  defp case_terms(list) when is_list(list), do: Enum.map(list, &case_terms/1)

  defp case_terms(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp case_terms(value), do: value
end
