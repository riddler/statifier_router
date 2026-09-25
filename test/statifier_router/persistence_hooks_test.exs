defmodule StatifierRouter.PersistenceHooksTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Event
  alias StatifierPersistence.Executions
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestRepo

  # ADR-0003, the Amendment of 2026-09-25: `:on_create` and `:on_step` stand
  # in for statifier_persistence's `create/4` and `step/5`. Each is handed
  # exactly the arguments the direct call would be, inside the delivery's
  # transaction, and its answer is read as persistence's would be.

  @now ~U[2026-09-25 08:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  # The hooks every test starts from: report the arguments to `pid`, then
  # make the direct call and answer what it answered.
  defp recording_create(pid) do
    fn store, execution_id, machine, opts ->
      send(pid, {:on_create, store, execution_id, machine, opts})
      Executions.create(store, execution_id, machine, opts)
    end
  end

  defp recording_step(pid) do
    fn store, execution_id, machine, event, opts ->
      send(pid, {:on_step, store, execution_id, machine, event, opts})
      Executions.step(store, execution_id, machine, event, opts)
    end
  end

  # A parcel configuration with a send type, so the snapshot the two calls
  # carry is not empty and its placement on each is visible.
  defp parcel_config(opts) do
    config(self(), [bindings: parcel_bindings(), send_type: "myapp:parcel"] ++ opts)
  end

  defp scan(message_id, kind), do: parcel_scan(message_id, kind)

  defp scanned(kind), do: Event.external(kind, data: %{"parcel_id" => "pcl_4821"})

  describe "the arguments" do
    # sabotage: persistence_create/4 handed the hook its opts without
    # `initialize:` -> the opts no longer equalled the direct call's, red;
    # restored, green. Second mutation: persistence_step/5 handed the hook
    # the event with its data set to nil -> red; restored, green.
    test "each hook receives exactly the arguments the direct call would" do
      config =
        parcel_config(on_create: recording_create(self()), on_step: recording_step(self()))

      machine = Map.fetch!(machines(), "parcel_route")
      store = config.store
      create_opts = [executor: config.executor, initialize: config.persistence_options]
      step_opts = [{:executor, config.executor} | config.persistence_options]

      assert [send_types: _] = config.persistence_options

      assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert_received {:on_create, ^store, ^execution_id, ^machine, ^create_opts}
      loaded = scanned("loaded")
      assert_received {:on_step, ^store, ^execution_id, ^machine, ^loaded, ^step_opts}

      assert {:ok, [_, {:delivered, "delivered_scans", ^execution_id}]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0002", "delivered"), now: @now)

      refute_received {:on_create, _, _, _, _}
      delivered = scanned("delivered")
      assert_received {:on_step, ^store, ^execution_id, ^machine, ^delivered, ^step_opts}

      assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]
    end

    # sabotage: call_hook/3's module clause applied `function` to the
    # arguments less the store -> UndefinedFunctionError, red; restored,
    # green.
    test "a module is called as module.create/4 and module.step/5" do
      config = parcel_config(on_create: Executions, on_step: Executions)

      assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert {:ok, [_, {:delivered, "delivered_scans", ^execution_id}]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0002", "delivered"), now: @now)

      assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]
    end
  end

  describe ":on_create's answer" do
    # sabotage: create/6's terminal check on the answered execution was
    # replaced by `false` -> the scan came back created_and_delivered and
    # the step hook was called, red; restored, green.
    test "the ok arm is honoured: an execution it answers terminal is dropped: finished, unstepped" do
      on_create = fn store, execution_id, machine, opts ->
        {:ok, execution, state} = Executions.create(store, execution_id, machine, opts)
        {:ok, %{execution | status: :completed}, state}
      end

      config = parcel_config(on_create: on_create, on_step: recording_step(self()))

      assert {:ok, [{:dropped, "loaded_scans", :finished}, {:no_match, "delivered_scans"}]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      refute_received {:on_step, _, _, _, _, _}
      assert [%Ledger{outcome: "dropped: finished", execution_id: "ex_" <> _}] = ledger(config)
    end

    # sabotage: persistence_create/4 answered `{:ok, nil, nil}` for an
    # `{:error, _}` from the hook -> a KeyError in place of the error,
    # red; restored, green.
    test "the error arm rolls the delivery back to its savepoint, the hook's own writes with it" do
      on_create = fn store, execution_id, machine, opts ->
        {:ok, _execution, _state} = Executions.create(store, execution_id, machine, opts)
        {:error, :host_refused}
      end

      config = parcel_config(on_create: on_create)

      assert StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now) ==
               {:error, :host_refused}

      # The execution the hook created was written inside the delivery's
      # transaction, and the rollback took it with the rest.
      assert executions() == 0
      assert addresses(config) == []
      assert ledger(config) == []
    end

    # sabotage: persistence_create/4's catch-all arm returned the answer
    # as given -> no ArgumentError, red; restored, green.
    test "an answer outside create/4's contract raises and leaves nothing" do
      config = parcel_config(on_create: fn _store, _id, _machine, _opts -> {:discarded, nil} end)

      assert_raise ArgumentError, ~r/:on_create answered \{:discarded, nil\}/, fn ->
        StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)
      end

      assert addresses(config) == []
    end
  end

  describe ":on_step's answer" do
    # sabotage: persistence_step/5's ok arm answered the hook's state with
    # `last_selection: :selected` -> the scan came back
    # created_and_delivered, red; restored, green.
    test "the ok arm is honoured: a state it answers unselected is dropped: unmatched_event" do
      on_step = fn store, execution_id, machine, event, opts ->
        {:ok, execution, state} = Executions.step(store, execution_id, machine, event, opts)
        {:ok, execution, %{state | last_selection: :none}}
      end

      config = parcel_config(on_step: on_step)

      assert {:ok, [{:dropped, "loaded_scans", :unmatched_event}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert [%Ledger{outcome: "dropped: unmatched_event", execution_id: execution_id}] =
               ledger(config)

      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: persistence_step/5's `{:discarded, _}` arm was removed ->
    # an ArgumentError in place of the outcome, red; restored, green.
    test "the discarded arm is honoured: dropped: finished, and the address row is stamped" do
      on_step = fn store, execution_id, machine, event, opts ->
        {:ok, execution, _state} = Executions.step(store, execution_id, machine, event, opts)
        {:discarded, execution}
      end

      config = parcel_config(on_step: on_step)

      assert {:ok, [{:dropped, "loaded_scans", :finished}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert [%Address{key: "pcl_4821", terminal_seen_at: @now}] = addresses(config)
      assert [%Ledger{outcome: "dropped: finished"}] = ledger(config)
    end

    # sabotage: persistence_step/5 answered `{:discarded, nil}` for an
    # `{:error, _}` from the hook -> the delivery settled as dropped:
    # finished and committed, red; restored, green.
    test "the error arm rolls the delivery back to its savepoint, the created execution with it" do
      config =
        parcel_config(on_step: fn _store, _id, _machine, _event, _opts -> {:error, :held} end)

      assert StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now) ==
               {:error, :held}

      assert executions() == 0
      assert addresses(config) == []
      assert ledger(config) == []
    end

    # sabotage: persistence_step/5's catch-all arm returned the answer as
    # given -> no ArgumentError, red; restored, green.
    test "an answer outside step/5's contract raises" do
      config = parcel_config(on_step: fn _store, _id, _machine, _event, _opts -> :ok end)

      assert_raise ArgumentError, ~r/:on_step answered :ok/, fn ->
        StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)
      end
    end
  end
end
