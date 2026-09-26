defmodule StatifierRouter.PersistenceHooksTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Send
  alias Statifier.Event
  alias StatifierPersistence.Executions
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.SendHandler
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

  describe "the execution-to-execution door" do
    # ADR-0006: a send to the `execution` target is delivered by
    # `StatifierRouter.Delivery.deliver_event/4`, which settles through the
    # same create and step as route/3, so the hooks and the host's
    # `:execution_id` stand in there too. The sender is a parcel created by
    # a scan; the target is a second parcel on the same route.

    # A send from the sender's step, of the configuration's send type, to
    # the parcel `key` on `parcel_route`.
    defp parcel_send(event, key, ordinal) do
      %Send{
        event: event,
        target: "execution",
        type: "myapp:parcel",
        data: %{"document" => "parcel_route", "key" => key},
        send_id: "send_1",
        c_index: 3,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        round: 0,
        ordinal: ordinal
      }
    end

    defp seam(execution_id), do: %{execution_id: execution_id, content_hash: "sha_1"}

    # Reports each call to `pid` and answers a `trip_` id named for the
    # key, a fictional prefix of the kind a host would choose.
    defp target_ids(pid) do
      fn scope, document, key ->
        send(pid, {:minted, scope, document, key})
        "trip_" <> key
      end
    end

    # The sender's own create and step went through the hooks too; drop
    # their reports so every assertion below reads the door's alone.
    defp flush_hook_reports do
      receive do
        {:minted, _, _, _} -> flush_hook_reports()
        {:on_create, _, _, _, _} -> flush_hook_reports()
        {:on_step, _, _, _, _, _} -> flush_hook_reports()
      after
        0 -> :ok
      end
    end

    # sabotage: deliver_event/4 settled with `on_create`, `on_step` and
    # `execution_id` set to nil on the configuration -> the direct calls
    # ran, no hook reported and the target's id was a UXID, red; restored,
    # green. Second mutation: `on_step` alone set to nil there -> no
    # :on_step report for the target, red; restored, green.
    test "a send that creates its target calls :execution_id, :on_create and :on_step" do
      config =
        parcel_config(
          on_create: recording_create(self()),
          on_step: recording_step(self()),
          execution_id: target_ids(self())
        )

      machine = Map.fetch!(machines(), "parcel_route")
      store = config.store
      create_opts = [executor: config.executor, initialize: config.persistence_options]
      step_opts = [{:executor, config.executor} | config.persistence_options]

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_pcl_4821" = sender}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      flush_hook_reports()

      assert SendHandler.handle_effect(
               config,
               {:send, parcel_send("loaded", "pcl_5930", 1)},
               seam(sender)
             ) == :ok

      assert_received {:minted, "7c1e", "parcel_route", "pcl_5930"}
      assert_received {:on_create, ^store, "trip_pcl_5930", ^machine, ^create_opts}

      assert_received {:on_step, ^store, "trip_pcl_5930", ^machine,
                       %Event{name: "loaded", origin: origin}, ^step_opts}

      assert origin == "#_scxml_" <> sender

      assert %Address{execution_id: "trip_pcl_5930"} =
               Enum.find(addresses(config), &(&1.key == "pcl_5930"))

      assert %Ledger{
               binding_id: "execution",
               outcome: "created_and_delivered",
               key: "pcl_5930",
               execution_id: "trip_pcl_5930"
             } = List.last(ledger(config))

      assert inputs(config, "trip_pcl_5930") == [{0, "step", "loaded"}]
    end

    # sabotage: both mutations above -> no :on_step report for the second
    # send, red; restored, green.
    test "a send to a target that exists calls :on_step alone, and mints nothing" do
      config =
        parcel_config(
          on_create: recording_create(self()),
          on_step: recording_step(self()),
          execution_id: target_ids(self())
        )

      machine = Map.fetch!(machines(), "parcel_route")
      store = config.store
      step_opts = [{:executor, config.executor} | config.persistence_options]

      assert {:ok, [{:created_and_delivered, "loaded_scans", sender}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert :ok =
               SendHandler.handle_effect(
                 config,
                 {:send, parcel_send("loaded", "pcl_5930", 1)},
                 seam(sender)
               )

      flush_hook_reports()

      assert SendHandler.handle_effect(
               config,
               {:send, parcel_send("delivered", "pcl_5930", 2)},
               seam(sender)
             ) == :ok

      refute_received {:minted, _, _, _}
      refute_received {:on_create, _, _, _, _}

      assert_received {:on_step, ^store, "trip_pcl_5930", ^machine, %Event{name: "delivered"},
                       ^step_opts}

      assert %Ledger{outcome: "delivered", key: "pcl_5930", execution_id: "trip_pcl_5930"} =
               List.last(ledger(config))

      assert inputs(config, "trip_pcl_5930") == [{0, "step", "loaded"}, {1, "step", "delivered"}]
    end
  end
end
