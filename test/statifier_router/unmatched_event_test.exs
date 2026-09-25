defmodule StatifierRouter.UnmatchedEventTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestRepo

  # ADR-0004, the Note of 2026-09-25: a binding's delivery whose step took
  # the event and selected no transition for it is dropped: unmatched_event,
  # read off the `last_selection` the stepped state carries. The event is
  # in the input log all the same, because `step/5` appended it.

  @now ~U[2026-09-25 08:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  # sabotage: taken/7 matched `last_selection: :selected` in place of
  # `:none` -> the second loaded scan came back delivered and the ledger
  # read "delivered", red; restored, green.
  test "an event the current state has no transition for is dropped: unmatched_event" do
    config = config(self(), bindings: parcel_bindings())

    {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
      StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

    # A second loaded scan: the parcel is on the van, which takes no
    # `loaded`.
    assert StatifierRouter.route(config, parcel_scan("parcel_scans/1/0002", "loaded"), now: @now) ==
             {:ok, [{:dropped, "loaded_scans", :unmatched_event}, {:no_match, "delivered_scans"}]}

    assert [_created, unmatched] = ledger(config)

    assert %Ledger{
             binding_id: "loaded_scans",
             message_id: "parcel_scans/1/0002",
             scope: "7c1e",
             outcome: "dropped: unmatched_event",
             key: "pcl_4821",
             execution_id: ^execution_id,
             reason: nil
           } = unmatched

    # The step took the event: the input log holds it, as for a delivery.
    assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "loaded"}]
  end

  # sabotage: held_parcel_route's `delivered` transition was made
  # unguarded in the fixture -> the scan moved the chart and came back
  # delivered, red; restored, green. It shows the false guard, not a
  # missing event name, is what the step did not take here.
  test "an event whose only guard is false is dropped: unmatched_event, the same outcome as an ignored event" do
    config = config(self(), bindings: parcel_bindings("held_parcel_route"))

    {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
      StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

    assert StatifierRouter.route(
             config,
             parcel_scan("parcel_scans/1/0002", "delivered"),
             now: @now
           ) ==
             {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :unmatched_event}]}

    assert %Ledger{
             binding_id: "delivered_scans",
             outcome: "dropped: unmatched_event",
             key: "pcl_4821",
             execution_id: ^execution_id
           } = List.last(ledger(config))

    assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]
  end

  # sabotage: taken/7's `:none` clause lost its match on the selection and
  # recorded every step as dropped: unmatched_event -> the delivered scan
  # that finished the chart came back dropped, red; restored, green.
  test "an event that moves the chart is delivered" do
    config = config(self(), bindings: parcel_bindings())

    {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
      StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

    assert StatifierRouter.route(
             config,
             parcel_scan("parcel_scans/1/0002", "delivered"),
             now: @now
           ) ==
             {:ok, [{:no_match, "loaded_scans"}, {:delivered, "delivered_scans", execution_id}]}

    assert ["created_and_delivered", "delivered"] = Enum.map(ledger(config), & &1.outcome)
  end

  # sabotage: taken/7's `:none` clause was limited to the `:delivered`
  # outcome -> the first scan came back created_and_delivered, red;
  # restored, green.
  test "a created execution whose first event matches nothing is dropped: unmatched_event, and stays" do
    config = config(self(), bindings: parcel_bindings())

    # A delivered scan before any loaded scan: the create runs, and the
    # depot takes no `delivered`.
    assert StatifierRouter.route(
             config,
             parcel_scan("parcel_scans/1/0001", "delivered"),
             now: @now
           ) ==
             {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :unmatched_event}]}

    # The create stands: the execution, its address row and the event in
    # its input log are all there, and the ledger row names the execution.
    assert [%Address{key: "pcl_4821", execution_id: execution_id, terminal_seen_at: nil}] =
             addresses(config)

    assert executions() == 1
    assert inputs(config, execution_id) == [{0, "step", "delivered"}]

    assert [
             %Ledger{
               binding_id: "delivered_scans",
               outcome: "dropped: unmatched_event",
               key: "pcl_4821",
               execution_id: ^execution_id
             }
           ] = ledger(config)

    # The execution is where it started, and still takes a loaded scan.
    assert {:ok, [{:delivered, "loaded_scans", ^execution_id}, _]} =
             StatifierRouter.route(config, parcel_scan("parcel_scans/1/0002", "loaded"),
               now: @now
             )
  end
end
