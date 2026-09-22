defmodule StatifierRouter.SourceInvokeTest do
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Invoke
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Subscription
  alias StatifierRouter.SourceInvoke
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-19 08:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  # The execution the impression-and-click join's first event creates, with
  # the address row every subscription below reads its scope and key from.
  defp joined_execution(config) do
    assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
             StatifierRouter.route(config, impression(), now: @now)

    execution_id
  end

  defp subscriptions(config),
    do: TestRepo.all(from(s in Config.queryable(config, Subscription), order_by: s.id))

  defp invoke(invoke_id, params) do
    %Invoke{
      invoke_id: invoke_id,
      type: "myapp:source",
      params: params,
      state_index: 1,
      invoke_index: 0,
      macrostep: 1,
      microstep: 0,
      round: 1
    }
  end

  defp cancel_invoke(invoke_id) do
    %CancelInvoke{invoke_id: invoke_id, state_index: 1, macrostep: 2, microstep: 0, round: 2}
  end

  describe "subscribe/3 and cancel/2" do
    # sabotage: subscribe/3 wrote the binding's own document in place of the
    # address row's key -> the row's key came back "impression_click_join",
    # red; restored, green.
    test "a subscription records the scope and key the execution is addressed under" do
      config = config(self())
      execution_id = joined_execution(config)

      assert StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"}) ==
               {:ok, :subscribed}

      assert [
               %Subscription{
                 binding_id: "clicks_to_join",
                 execution_id: ^execution_id,
                 invoke_id: "inv_1",
                 scope: "7c1e",
                 key: "imp_7f3a"
               }
             ] = subscriptions(config)
    end

    # sabotage: the insert dropped `on_conflict: :nothing` -> the second
    # subscribe raised Ecto.ConstraintError, red; restored, green.
    test "subscribing twice for one invocation is harmless and writes one row" do
      config = config(self())
      execution_id = joined_execution(config)

      assert StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"}) ==
               {:ok, :subscribed}

      assert StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"}) ==
               {:ok, :already_subscribed}

      assert [%Subscription{}] = subscriptions(config)
    end

    # sabotage: cancel/2 matched on execution_id and binding_id only ->
    # the first cancel deleted both rows, red on the second invocation's
    # row surviving; restored, green.
    test "cancel/2 deletes its own invocation's row and leaves the other one" do
      config = config(self())
      execution_id = joined_execution(config)

      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"})

      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_2"})

      assert StatifierRouter.cancel(config, {"clicks_to_join", execution_id, "inv_1"}) ==
               {:ok, :cancelled}

      assert [%Subscription{invoke_id: "inv_2"}] = subscriptions(config)
    end

    # sabotage: cancel/2 answered {:ok, :cancelled} for a delete of zero
    # rows -> the second cancel came back :cancelled, red; restored, green.
    test "cancelling twice is harmless, and so is cancelling what was never subscribed" do
      config = config(self())
      execution_id = joined_execution(config)

      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"})

      assert StatifierRouter.cancel(config, {"clicks_to_join", execution_id, "inv_1"}) ==
               {:ok, :cancelled}

      assert StatifierRouter.cancel(config, {"clicks_to_join", execution_id, "inv_1"}) ==
               {:ok, :not_subscribed}

      assert StatifierRouter.cancel(config, {"clicks_to_join", execution_id, "never"}) ==
               {:ok, :not_subscribed}

      assert subscriptions(config) == []
    end

    # ADR-0007, section 6: an always_new create writes no address row, so
    # the execution has no key to subscribe under and the invocation is
    # refused rather than subscribed under an invented one.
    #
    # sabotage: subscribe/3 fell back to the binding's document as the key
    # when no address row was found -> the refusal became {:ok, :subscribed},
    # red; restored, green.
    test "an execution with no address row is refused rather than subscribed" do
      config = config(self(), bindings: [always_new_impressions(), clicks()])

      assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert addresses(config) == []

      assert StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"}) ==
               {:error, {:unaddressed_execution, execution_id}}

      assert subscriptions(config) == []
    end

    # sabotage: known_binding/2 returned :ok for every id -> the call
    # reached the address read and answered {:ok, :subscribed}, red;
    # restored, green.
    test "a binding the configuration does not carry is refused" do
      config = config(self())
      execution_id = joined_execution(config)

      assert StatifierRouter.subscribe(config, "no_such_binding", {execution_id, "inv_1"}) ==
               {:error, {:unknown_binding, "no_such_binding"}}

      assert subscriptions(config) == []
    end
  end

  describe "the delegate a host's invoke handler calls" do
    # sabotage: start/3 read the invoke's `type` as the binding id -> the
    # call was refused with {:unknown_binding, "myapp:source"}, red;
    # restored, green.
    test "start/3 subscribes under the invoke's binding param and its own invoke_id" do
      config = config(self())
      execution_id = joined_execution(config)

      assert SourceInvoke.start(
               config,
               execution_id,
               invoke("inv_7", %{"binding" => "clicks_to_join"})
             ) == {:ok, :subscribed}

      assert [%Subscription{binding_id: "clicks_to_join", invoke_id: "inv_7"}] =
               subscriptions(config)
    end

    # An <invoke> with no <param> at all resolves to :undefined rather than
    # an empty map (Statifier.EventData, statifier 2.6.0), so both spellings
    # of "no binding named" are refused here.
    #
    # sabotage: binding_id/1 accepted an empty string -> the empty-binding
    # call reached subscribe/3 and answered {:unknown_binding, ""}, red;
    # restored, green.
    test "start/3 refuses an invoke that names no binding" do
      config = config(self())
      execution_id = joined_execution(config)

      assert SourceInvoke.start(config, execution_id, invoke("inv_7", :undefined)) ==
               {:error, {:missing_binding_param, :undefined}}

      assert SourceInvoke.start(config, execution_id, invoke("inv_7", %{"binding" => ""})) ==
               {:error, {:missing_binding_param, %{"binding" => ""}}}

      assert subscriptions(config) == []
    end

    # The engine's cancellation carries an invoke_id and no binding, so the
    # delegate reads the binding back off the row.
    #
    # sabotage: subscribed_binding/3 matched on invoke_id alone -> it read
    # the other execution's row, which is the first in id order here and
    # names another binding, so the cancel answered :not_subscribed, red;
    # restored, green.
    test "cancel/3 finds the binding by the invocation, and tolerates one it does not know" do
      config = config(self())
      first = joined_execution(config)

      assert {:ok, [{:created_and_delivered, "impressions_to_join", second}, _]} =
               StatifierRouter.route(
                 config,
                 event("ad_events/3/2042", %{
                   "kind" => "impression",
                   "impression_id" => "imp_91ab",
                   "placement" => "sidebar"
                 }),
                 now: @now
               )

      # The other execution's row goes in first, and under another binding,
      # so a lookup that ignored the execution would read this one.
      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "impressions_to_join", {second, "inv_7"})

      {:ok, :subscribed} = StatifierRouter.subscribe(config, "clicks_to_join", {first, "inv_7"})

      assert SourceInvoke.cancel(config, first, cancel_invoke("inv_7")) == {:ok, :cancelled}

      assert [%Subscription{execution_id: ^second, binding_id: "impressions_to_join"}] =
               subscriptions(config)

      assert SourceInvoke.cancel(config, first, cancel_invoke("inv_7")) == {:ok, :not_subscribed}
    end
  end

  describe "what a subscription does not change" do
    # ADR-0007's "every event it wants arrives through the ordinary binding
    # path", pinned so that a later reader does not mistake the subscription
    # row for a gate on delivery: the click reaches the execution the same
    # way whether or not a subscription is live. This record specifies no
    # route/3 consultation of the table, and route/3 has none.
    #
    # No sabotage note: this test pins an absence, and the mutations that
    # would break it are mutations to route/3, which this bead does not
    # touch. The discriminating mutations for subscribe/3 and cancel/2 are
    # on the tests above.
    test "an event routes through its binding whether or not the invocation is subscribed" do
      config = config(self())
      subscribed = joined_execution(config)

      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "clicks_to_join", {subscribed, "inv_1"})

      assert {:ok, [_, {:delivered, "clicks_to_join", ^subscribed}]} =
               StatifierRouter.route(config, click("ad_events/3/1107"), now: @now)

      # A second execution, subscribed and then cancelled, takes its click
      # exactly the same way. The click ends the join chart, so each half
      # of the comparison needs an execution of its own.
      assert {:ok, [{:created_and_delivered, "impressions_to_join", cancelled}, _]} =
               StatifierRouter.route(
                 config,
                 event("ad_events/3/2042", %{
                   "kind" => "impression",
                   "impression_id" => "imp_91ab",
                   "placement" => "sidebar"
                 }),
                 now: @now
               )

      {:ok, :subscribed} =
        StatifierRouter.subscribe(config, "clicks_to_join", {cancelled, "inv_1"})

      {:ok, :cancelled} = StatifierRouter.cancel(config, {"clicks_to_join", cancelled, "inv_1"})

      assert {:ok, [_, {:delivered, "clicks_to_join", ^cancelled}]} =
               StatifierRouter.route(
                 config,
                 event("ad_events/3/2107", %{
                   "kind" => "click",
                   "impression_id" => "imp_91ab",
                   "url" => "https://example.com/offer"
                 }),
                 now: @now
               )
    end
  end

  defp always_new_impressions,
    do: Map.merge(Enum.at(bindings(), 0), %{create: :always_new})

  defp clicks, do: Enum.at(bindings(), 1)
end
