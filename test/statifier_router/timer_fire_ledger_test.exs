defmodule StatifierRouter.TimerFireLedgerTest do
  # A fired timer is not a routed delivery (ADR-0004, the Note of
  # 2026-10-02 on timer fires). The parcel chart below arms a delivery
  # window when the parcel is loaded onto the van; the window closing is a
  # delayed send. It is scheduled on a real timer queue, statifier_oban on
  # the suite's Oban instance, and fired by draining that queue, through a
  # delivery module written the way a process-less host writes one. These
  # tests pin today's behaviour: a fire into a live execution and a fire
  # into a finished one each write no routing ledger row and leave the
  # address table as it was, while a routed delivery to the same finished
  # execution writes one row. A fire into a finished execution is seen on
  # the timer job instead.
  #
  # The executor hands every effect to `StatifierRouter.SendHandler`, the
  # router's own effect seam, as a host's executor does, and the fire step
  # arms a second window, so a fire passes through that seam too.
  use ExUnit.Case, async: true, group: :database

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.SendDelayed
  alias Statifier.Machine
  alias StatifierOban.Timer
  alias StatifierPersistence.Storage
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo

  @now ~U[2026-10-02 08:00:00.000000Z]
  @scope "7c1e"
  @document "windowed_parcel_route"

  # The Oban instance test/test_helper.exs starts, in manual testing mode:
  # a job fires only when a test drains its queue. The queue is this
  # file's own, so a drain here never fires another file's timers.
  @oban StatifierRouter.TestOban
  @queue :parcel_window_timers

  # A parcel loaded onto the van gets a delivery window. If the window
  # closes before a `delivered` scan, the parcel waits for a second
  # attempt, which arms a second window; a `delivered` scan finishes the
  # execution either way.
  @windowed_parcel """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
    <state id="at_depot">
      <transition event="loaded" target="on_van"/>
    </state>
    <state id="on_van">
      <onentry>
        <send id="window" event="delivery_window.closed" delay="2s"/>
      </onentry>
      <transition event="delivery_window.closed" target="awaiting_second_attempt"/>
      <transition event="delivered" target="doorstep"/>
    </state>
    <state id="awaiting_second_attempt">
      <onentry>
        <send id="second_window" event="second_window.closed" delay="2s"/>
      </onentry>
      <transition event="delivered" target="doorstep"/>
    </state>
    <final id="doorstep"/>
  </scxml>
  """

  defmodule WindowDelivery do
    # The timer queue's delivery for these tests, as a process-less host
    # writes one: the scope is the execution's id, and the fired event is
    # one more step of the execution, which a terminal execution discards.
    # The job is drained in the test's own process, so the configuration
    # is read from there.
    @moduledoc false
    @behaviour StatifierOban.Timer.Delivery

    alias StatifierOban.Timer.Delivery
    alias StatifierPersistence.Storage
    alias StatifierRouter.CorpusRunner

    @impl Delivery
    def deliver(execution_id, effect) do
      config = Process.get(StatifierRouter.TimerFireLedgerTest)
      {:ok, record} = Storage.fetch_execution(config.store, execution_id)
      event = Delivery.fired_event(execution_id, effect)

      case CorpusRunner.step_fired(config, execution_id, record.content_hash, event) do
        {:ok, _execution} -> :delivered
        {:discarded, execution} -> {:discarded, execution.status}
      end
    end
  end

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "a fired timer" do
    # sabotage: WindowDelivery.deliver/2 also handed the fired event to
    # StatifierRouter.Delivery.deliver_event/4 under an "execution" plan
    # after the step (the router-owned timer delivery this file pins the
    # absence of) -> the ledger gained a row and the ledger assertion
    # failed, red; restored, green. Second mutation, in lib: SendHandler's
    # handle_effect/3 wrote a ledger row for the second window's
    # :send_delayed effect, which only the fire step emits -> the same
    # assertion failed, red; restored, green. Third: WindowDelivery.deliver/2
    # also stamped the address row's terminal_seen_at -> the address
    # assertion failed, red; restored, green.
    test "into a live execution steps it and writes no ledger row" do
      config = windowed_config()

      assert {:created_and_delivered, "loaded_scans", execution} =
               scan(config, "parcel_scans/1/1", "loaded")

      job = schedule(execution, armed_window())
      ledger = ledger(config)
      addresses = addresses(config)
      assert [%{outcome: "created_and_delivered"}] = ledger

      assert %{success: 1, cancelled: 0} = drain()

      assert ledger(config) == ledger
      assert addresses(config) == addresses

      # The fire reached the execution: its input log holds the fired event
      # after the loaded scan, the execution is still live, and the fire
      # step armed the second window through the executor and the router's
      # effect seam behind it.
      assert [{0, "step", "loaded"}, {1, "step", "delivery_window.closed"}] =
               inputs(config, execution)

      assert {:ok, %{status: :active}} = Storage.fetch_execution(config.store, execution)
      assert_received {:effect, {:send_delayed, %SendDelayed{event: "second_window.closed"}}}
      assert %Oban.Job{state: "completed"} = TestRepo.reload!(job)
    end

    # sabotage: WindowDelivery.deliver/2 also handed the fired event to
    # StatifierRouter.Delivery.deliver_event/4 after the step, as above ->
    # that door wrote a dropped: finished row and the first ledger
    # assertion failed, red; restored, green. Second: WindowDelivery's
    # address stamp, as above -> the address assertion failed, red;
    # restored, green. Third, in lib: finished/6 in
    # StatifierRouter.Delivery skipped its record/6 call -> the routed
    # control found no new row, red; restored, green.
    test "into a finished execution is discarded on its job and writes no ledger row, where a routed delivery writes one" do
      config = windowed_config()

      assert {:created_and_delivered, "loaded_scans", execution} =
               scan(config, "parcel_scans/1/1", "loaded")

      job = schedule(execution, armed_window())

      assert {:delivered, "delivered_scans", ^execution} =
               scan(config, "parcel_scans/1/2", "delivered")

      assert {:ok, %{status: :completed}} = Storage.fetch_execution(config.store, execution)

      ledger = ledger(config)
      addresses = addresses(config)
      inputs = inputs(config, execution)

      assert %{success: 0, cancelled: 1} = drain()

      assert ledger(config) == ledger
      assert addresses(config) == addresses
      assert inputs(config, execution) == inputs

      # Where a host sees the fire: the job is cancelled with the
      # delivery's discard, and the execution's stored status, recorded on
      # its row.
      assert %Oban.Job{state: "cancelled", errors: [%{"error" => error}]} =
               TestRepo.reload!(job)

      assert error =~ "discarded"
      assert error =~ "completed"

      # The control: a routed delivery to the same finished execution is a
      # recorded outcome, so the ledger the fire left alone is one that
      # does take rows for this execution.
      assert {:dropped, "delivered_scans", :finished} =
               scan(config, "parcel_scans/1/3", "delivered")

      assert [%{outcome: "dropped: finished", execution_id: ^execution}] =
               ledger(config) -- ledger
    end
  end

  # Routes one scan and answers the outcome of the binding it was for; the
  # other parcel binding answers no_match and is left out.
  defp scan(config, message_id, kind) do
    assert {:ok, outcomes} =
             StatifierRouter.route(config, parcel_scan(message_id, kind), now: @now)

    assert [outcome] = Enum.reject(outcomes, &match?({:no_match, _binding}, &1))
    outcome
  end

  # The window the `loaded` step armed, as the executor was handed it.
  defp armed_window do
    assert_received {:effect,
                     {:send_delayed, %SendDelayed{event: "delivery_window.closed"} = timer}}

    timer
  end

  # Schedules the window on the timer queue under its execution's id, the
  # scope a process-less host schedules under.
  defp schedule(execution_id, %SendDelayed{} = timer) do
    {:ok, timers} =
      StatifierOban.Config.new(oban: @oban, timers_queue: @queue, delivery: WindowDelivery)

    assert {:ok, %Oban.Job{conflict?: false, id: id}} =
             Timer.schedule(timers, execution_id, timer)

    TestRepo.one!(from(j in Oban.Job, where: j.id == ^id))
  end

  # Fires every job on this file's queue, in this process. A delivery that
  # raises is raised here rather than left on the queue as a retry.
  defp drain do
    Oban.drain_queue(@oban, queue: @queue, with_scheduled: true, with_safety: false)
  end

  defp windowed_config do
    {:ok, machine} = Statifier.compile(@windowed_parcel)
    {:ok, static} = Static.new(%{{@scope, @document} => machine})
    hash = Machine.identity(machine).content_hash
    test = self()

    config =
      config(test,
        resolver: static,
        chart_resolver: fn
          ^hash -> {:ok, machine}
          _other -> :error
        end,
        bindings: parcel_bindings(@document)
      )

    executor = fn effect, context ->
      send(test, {:effect, effect})
      SendHandler.handle_effect(config, effect, context)
    end

    config = %{config | executor: executor}
    Process.put(__MODULE__, config)
    config
  end
end
