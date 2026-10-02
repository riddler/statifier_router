defmodule StatifierRouter.LatePartnerTest do
  # A late event for a finished execution's key, before and after
  # StatifierRouter.Addresses.reap/3 deletes the execution's address row,
  # under each `create` mode (ADR-0002, section 6 and its Note of
  # 2026-10-02 on the late partner). The parcel chart opens on a `loaded`
  # scan and finishes on a `delivered` scan; a `delivered` scan that
  # reaches the router after the parcel's execution finished is the late
  # partner. These tests pin today's behaviour: the reap horizon is the
  # longest dedupe horizon of any enabled binding naming the document, and
  # once the row is gone an `:if_absent` binding opens a second execution
  # for the key.
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Addresses
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestRepo

  @now ~U[2026-10-02 08:00:00.000000Z]
  @minute 60_000
  @hour 3_600_000

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "an :if_absent partner binding" do
    # sabotage: finished/6 stopped stamping terminal_seen_at -> the row's
    # stamp was nil after the late scan, red; restored, green. Second
    # mutation: due?/3 compared strictly (:lt) -> the reap one horizon
    # after the stamp deleted nothing, red; restored, green.
    test "a late delivered scan is dropped: finished before the reap, and opens a second execution after it" do
      config = config(self(), bindings: parcel(%{}, @hour))
      first = delivered_parcel(config)

      # Inside the horizon the row still names the finished execution.
      half_hour = at(30 * @minute)

      assert route(config, "parcel_scans/1/0003", "delivered", half_hour) ==
               {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :finished}]}

      assert [%Address{execution_id: ^first, terminal_seen_at: ^half_hour}] = addresses(config)
      assert executions() == 1

      # One hour from the stamp, the binding's dedupe horizon, the row goes.
      assert Addresses.reap(config, config.bindings, now: at(90 * @minute)) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert addresses(config) == []

      # The next late scan finds no row and opens a second execution for
      # the parcel, at the depot, where a delivered scan selects nothing.
      assert {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :unmatched_event}]} =
               route(config, "parcel_scans/1/0004", "delivered", at(2 * @hour))

      assert executions() == 2
      assert [%Address{key: "pcl_4821", execution_id: second}] = addresses(config)
      assert second != first
      assert inputs(config, second) == [{0, "step", "delivered"}]

      assert %Ledger{
               message_id: "parcel_scans/1/0004",
               outcome: "dropped: unmatched_event",
               execution_id: ^second
             } = List.last(ledger(config))
    end

    # sabotage: horizons/1 kept the shortest horizon of the bindings
    # naming the document (min) -> the reap at two hours deleted the row,
    # red; restored, green. Second mutation: horizons/1 kept the last
    # binding's horizon -> the reap at two hours deleted the row, red;
    # restored, green. Third mutation: horizons/1 dropped `enabled: true`
    # -> the disabled binding kept the row past three hours, red;
    # restored, green.
    test "the longest dedupe horizon of any enabled binding naming the document is the knob" do
      # The longest enabled horizon comes first, and a disabled binding
      # naming the same document carries a longer one still.
      disabled = delivered(%{id: "late_delivered_scans", enabled: false}, 10 * @hour)

      config =
        config(self(),
          bindings: [delivered(%{}, 3 * @hour), loaded(%{}, @hour), disabled]
        )

      first = delivered_parcel(config)

      assert {:ok, %{stamped: 1}} = Addresses.reap(config, config.bindings, now: @now)

      assert Addresses.reap(config, config.bindings, now: at(2 * @hour)) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert route(config, "parcel_scans/1/0003", "delivered", at(2 * @hour)) ==
               {:ok, [{:dropped, "delivered_scans", :finished}, {:no_match, "loaded_scans"}]}

      assert [%Address{execution_id: ^first}] = addresses(config)
      assert executions() == 1

      assert Addresses.reap(config, config.bindings, now: at(3 * @hour)) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}
    end
  end

  describe "a :never partner binding" do
    # sabotage: absent/4 sent a :never binding to insert_or_existing/4 ->
    # the late scan after the reap opened a second execution and came
    # back dropped: unmatched_event, red; restored, green.
    test "a late delivered scan is dropped: finished before the reap, and dropped: no_execution after it" do
      config = config(self(), bindings: [loaded(%{}, @hour), delivered(%{create: :never}, @hour)])
      first = delivered_parcel(config)

      assert route(config, "parcel_scans/1/0003", "delivered", at(30 * @minute)) ==
               {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :finished}]}

      assert Addresses.reap(config, config.bindings, now: at(90 * @minute)) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert route(config, "parcel_scans/1/0004", "delivered", at(2 * @hour)) ==
               {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :no_execution}]}

      assert addresses(config) == []
      assert executions() == 1
      assert inputs(config, first) == [{0, "step", "loaded"}, {1, "step", "delivered"}]

      assert %Ledger{
               message_id: "parcel_scans/1/0004",
               outcome: "dropped: no_execution",
               execution_id: nil
             } = List.last(ledger(config))
    end

    # sabotage: absent/4 sent a :never binding to insert_or_existing/4 ->
    # the early delivered scan opened an execution and came back dropped:
    # unmatched_event, red; restored, green.
    test "its cost: a delivered scan that arrives before its loaded scan is lost" do
      config = config(self(), bindings: [loaded(%{}, @hour), delivered(%{create: :never}, @hour)])

      assert route(config, "parcel_scans/1/0002", "delivered", @now) ==
               {:ok, [{:no_match, "loaded_scans"}, {:dropped, "delivered_scans", :no_execution}]}

      assert executions() == 0

      assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
               route(config, "parcel_scans/1/0001", "loaded", at(@minute))

      # The parcel stays on the van: the delivered scan never reached it.
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
      assert [%Address{execution_id: ^execution_id, terminal_seen_at: nil}] = addresses(config)
    end
  end

  describe "an :always_new binding" do
    # sabotage: by_mode/4 handled an :always_new binding as :if_absent ->
    # the second loaded scan reached the first execution and came back
    # dropped: unmatched_event, red; restored, green.
    test "every late scan opens its own execution, before and after a reap, which finds no row" do
      config = config(self(), bindings: [loaded(%{create: :always_new}, @hour)])

      assert {:ok, [{:created_and_delivered, "loaded_scans", first}]} =
               route(config, "parcel_scans/1/0001", "loaded", @now)

      assert {:ok, [{:created_and_delivered, "loaded_scans", second}]} =
               route(config, "parcel_scans/1/0002", "loaded", at(30 * @minute))

      assert addresses(config) == []

      assert Addresses.reap(config, config.bindings, now: at(90 * @minute)) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert {:ok, [{:created_and_delivered, "loaded_scans", third}]} =
               route(config, "parcel_scans/1/0003", "loaded", at(2 * @hour))

      assert Enum.uniq([first, second, third]) == [first, second, third]
      assert executions() == 3
      assert addresses(config) == []
    end
  end

  # The parcel loaded and delivered at @now through the configuration's
  # bindings: the delivered scan ends the chart, so the execution is
  # completed and its address row is not yet stamped.
  defp delivered_parcel(config) do
    {:ok, opened} = route(config, "parcel_scans/1/0001", "loaded", @now)
    [execution_id] = for {:created_and_delivered, "loaded_scans", id} <- opened, do: id

    {:ok, finished} = route(config, "parcel_scans/1/0002", "delivered", @now)
    assert {:delivered, "delivered_scans", execution_id} in finished

    assert [%Address{execution_id: ^execution_id, terminal_seen_at: nil}] = addresses(config)
    execution_id
  end

  defp route(config, message_id, kind, now),
    do: StatifierRouter.route(config, parcel_scan(message_id, kind), now: now)

  defp at(ms), do: DateTime.add(@now, ms, :millisecond)

  defp parcel(overrides, horizon_ms),
    do: [loaded(overrides, horizon_ms), delivered(overrides, horizon_ms)]

  defp loaded(overrides, horizon_ms), do: binding(0, overrides, horizon_ms)
  defp delivered(overrides, horizon_ms), do: binding(1, overrides, horizon_ms)

  defp binding(index, overrides, horizon_ms) do
    parcel_bindings()
    |> Enum.at(index)
    |> Map.put(:dedupe, %{by: :message_id, horizon_ms: horizon_ms})
    |> Map.merge(overrides)
  end
end
