defmodule StatifierRouter.DeliveryTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Types
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Delivery
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger}
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-19 08:00:00.000000Z]
  @later ~U[2026-09-19 09:00:00.000000Z]
  @discarded [:statifier_persistence, :execution, :discarded]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    %{config: config(self())}
  end

  describe "an :if_absent binding" do
    # sabotage: create/5 stepped with :delivered in place of
    # :created_and_delivered -> the first outcome came back delivered, red;
    # restored, green. Second mutation: existing/5 asked the document
    # resolver for the machine instead of the chart resolver -> a second
    # {:resolved, ...} arrived, red; restored, green.
    test "the first event creates the execution; a second event is delivered to it",
         %{config: config} do
      assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert "ex_" <> _ = execution_id
      assert_received {:resolved, "7c1e", "impression_click_join"}

      assert {:ok, [_, {:delivered, "clicks_to_join", ^execution_id}]} =
               StatifierRouter.route(config, click(), now: @now)

      refute_received {:resolved, _, _}

      assert [
               %Address{
                 scope: "7c1e",
                 document: "impression_click_join",
                 key: "imp_7f3a",
                 execution_id: ^execution_id,
                 terminal_seen_at: nil
               }
             ] = addresses(config)

      assert executions() == 1
      assert inputs(config, execution_id) == [{0, "step", "impression"}, {1, "step", "click"}]

      assert [
               %Ledger{
                 binding_id: "impressions_to_join",
                 message_id: "ad_events/3/1042",
                 scope: "7c1e",
                 outcome: "created_and_delivered",
                 key: "imp_7f3a",
                 execution_id: ^execution_id,
                 reason: nil,
                 inserted_at: @now
               },
               %Ledger{
                 binding_id: "clicks_to_join",
                 message_id: "ad_events/3/1107",
                 outcome: "delivered",
                 key: "imp_7f3a",
                 execution_id: ^execution_id
               }
             ] = ledger(config)
    end

    # sabotage: step/7 built the event without the binding's projected
    # data -> the stored event carried :undefined, red; restored, green.
    test "the execution is handed the binding's event with the projected data",
         %{config: config} do
      assert {:ok, [{:created_and_delivered, _, execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert {:ok, [entry]} = StatifierPersistence.Executions.inputs(config.store, execution_id)
      assert entry.event.name == "impression"
      assert entry.event.data == %{"impression_id" => "imp_7f3a", "placement" => "sidebar"}
    end

    # sabotage: existing/5 dropped its terminal check and stepped anyway
    # -> step/5 was called and reported a discard, red; restored, green.
    # Second mutation: stamp_terminal_seen/3 dropped the is_nil guard ->
    # the stamp moved to @later, red; restored, green.
    test "an event for a finished execution is dropped: finished, unstepped, and stamps the row once",
         %{config: config} do
      ref = :telemetry_test.attach_event_handlers(self(), [@discarded])
      on_exit(fn -> :telemetry.detach(ref) end)

      {:ok, [{:created_and_delivered, _, execution_id}, _]} =
        StatifierRouter.route(config, impression(), now: @now)

      {:ok, [_, {:delivered, _, ^execution_id}]} =
        StatifierRouter.route(config, click(), now: @now)

      assert StatifierRouter.route(config, click("ad_events/3/1311"), now: @now) ==
               {:ok,
                [{:no_match, "impressions_to_join"}, {:dropped, "clicks_to_join", :finished}]}

      assert StatifierRouter.route(config, click("ad_events/3/1400"), now: @later) ==
               {:ok,
                [{:no_match, "impressions_to_join"}, {:dropped, "clicks_to_join", :finished}]}

      # The status read decided it: step/5 was never called to discard.
      refute_received {@discarded, ^ref, _, %{execution_id: ^execution_id}}

      assert [%Address{execution_id: ^execution_id, terminal_seen_at: @now}] = addresses(config)
      assert inputs(config, execution_id) == [{0, "step", "impression"}, {1, "step", "click"}]

      assert [_, _, finished, _] = ledger(config)

      assert %Ledger{
               binding_id: "clicks_to_join",
               message_id: "ad_events/3/1311",
               outcome: "dropped: finished",
               key: "imp_7f3a",
               execution_id: ^execution_id
             } = finished
    end

    # sabotage: create/5 dropped its terminal check and stepped the
    # execution create/4 returned terminal -> step/5 was called and
    # reported a discard, red; restored, green.
    test "an execution created already terminal is dropped: finished with its id, unstepped",
         %{config: config} do
      ref = :telemetry_test.attach_event_handlers(self(), [@discarded])
      on_exit(fn -> :telemetry.detach(ref) end)

      binding = impression_binding(%{document: "instant_join"})
      delivery = delivery("ad_events/3/1042", "impression")

      assert {:dropped, "impressions_to_join", :finished} =
               Delivery.deliver(config, binding, "imp_7f3a", delivery)

      assert [
               %Address{
                 document: "instant_join",
                 execution_id: execution_id,
                 terminal_seen_at: @now
               }
             ] = addresses(config)

      refute_received {@discarded, ^ref, _, %{execution_id: ^execution_id}}
      assert executions() == 1
      assert input_rows() == 0

      assert [%Ledger{outcome: "dropped: finished", execution_id: ^execution_id, key: "imp_7f3a"}] =
               ledger(config)
    end
  end

  describe "the statifier_persistence snapshot options" do
    # sabotage: create_options/1 passed the snapshot beside the machine
    # instead of inside initialize: -> the create ran with no declaration,
    # the undeclared myapp:authorize emitted its effect anyway, red;
    # restored, green.
    test "reach the create inside initialize:, which is where the core reads them" do
      config = invoked_config(self(), ["myapp:capture"])

      assert {:ok, [{:created_and_delivered, "impressions_to_join", _execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      # The impression's step entered billing, whose type is declared.
      assert_received {:effect, {:invoke, %Invoke{type: "myapp:capture"}}}

      # The initial configuration's invoke is not declared, so the create
      # rejected it rather than emitting it.
      refute_received {:effect, {:invoke, %Invoke{type: "myapp:authorize"}}}
    end

    # sabotage: step_options/1 dropped the snapshot and passed only the
    # executor -> the step ran with no declaration, the undeclared
    # myapp:capture emitted its effect anyway, red; restored, green.
    test "reach the step beside the event" do
      config = invoked_config(self(), ["myapp:authorize"])

      assert {:ok, [{:created_and_delivered, "impressions_to_join", _execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert_received {:effect, {:invoke, %Invoke{type: "myapp:authorize"}}}
      refute_received {:effect, {:invoke, %Invoke{type: "myapp:capture"}}}
    end
  end

  describe "a delivery that does not commit" do
    # sabotage: record/6 rescued the ledger insert's raise, so the
    # transaction committed -> no raise, and an address row and an
    # execution survived, red; restored, green.
    test "a failing ledger insert rolls back the address row and the execution; the raise propagates",
         %{config: config} do
      # A table prefix whose address and dedupe tables exist, created in
      # this test's own sandbox transaction, and whose ledger does not: the
      # ledger insert, the last write of the transaction, fails after the
      # dedupe claim, create/4 and step/5 have run.
      for table <- ["addresses", "dedupe"] do
        SQL.query!(
          TestRepo,
          "CREATE TABLE ledgerless_#{table} (LIKE statifier_router_#{table} INCLUDING ALL)"
        )
      end

      ledgerless = %{config | table_prefix: "ledgerless_"}
      delivery = delivery("ad_events/3/1042", "impression")

      assert_raise Postgrex.Error, ~r/undefined_table/, fn ->
        Delivery.deliver(ledgerless, impression_binding(%{}), "imp_7f3a", delivery)
      end

      assert addresses(ledgerless) == []
      assert TestRepo.aggregate(Config.queryable(ledgerless, Dedupe), :count) == 0
      assert addresses(config) == []
      assert executions() == 0
      assert input_rows() == 0
      assert ledger(config) == []

      # The step's effect reached the executor before the rollback, and
      # stays fired (ADR-0003, section 2).
      assert_received {:effect, {:log, %{label: "impression_shown"}}}
    end

    # sabotage: deliver/4's transaction function returned {:error, reason}
    # instead of rolling back -> the address row committed, red; restored,
    # green. Second mutation: resolve/3 returned the resolver's
    # {:error, reason} as it came -> route/3 answered {:error, :not_found},
    # red; restored, green.
    test "an unresolvable document is route/3's error and creates nothing",
         %{config: config} do
      config = %{config | bindings: [%{hd(config.bindings) | document: "unpublished"}]}

      assert StatifierRouter.route(config, impression(), now: @now) ==
               {:error, {:unresolved_document, "unpublished", :not_found}}

      assert_received {:resolved, "7c1e", "unpublished"}
      assert addresses(config) == []
      assert TestRepo.aggregate(Config.queryable(config, Dedupe), :count) == 0
      assert executions() == 0
      assert input_rows() == 0
      assert ledger(config) == []
    end

    # sabotage: existing/5 asked the document resolver for the machine
    # instead of the chart resolver -> the click was delivered, red;
    # restored, green.
    test "an existing execution whose chart the host cannot resolve is an error",
         %{config: config} do
      {:ok, [{:created_and_delivered, _, execution_id}, _]} =
        StatifierRouter.route(config, impression(), now: @now)

      config = %{config | chart_resolver: fn _content_hash -> :error end}

      assert {:error, {:chart_not_resolved, "sha256:" <> _}} =
               StatifierRouter.route(config, click(), now: @now)

      assert inputs(config, execution_id) == [{0, "step", "impression"}]
      assert [%Ledger{outcome: "created_and_delivered"}] = ledger(config)
    end

    # sabotage: resolve/3 accepted any answer as the machine -> a
    # FunctionClauseError from create/4 instead, red; restored, green.
    test "a malformed resolver answer raises and leaves nothing", %{config: config} do
      config = %{config | resolver: fn _scope, _document -> :published end}

      assert_raise ArgumentError, ~r/the resolver answered :published/, fn ->
        StatifierRouter.route(config, impression(), now: @now)
      end

      assert addresses(config) == []
    end
  end

  defp impression_binding(overrides) do
    {:ok, binding} = Binding.new(Map.merge(hd(bindings()), overrides))
    binding
  end

  defp delivery(message_id, name) do
    %{
      name: name,
      data: %{"impression_id" => "imp_7f3a"},
      message_id: message_id,
      scope: "7c1e",
      now: @now
    }
  end

  defp invoked_config(pid, types) do
    config(pid,
      bindings: Enum.map(bindings(), &Map.put(&1, :document, "invoked_join")),
      persistence_options: [invoke_types: Types.new(types: types)]
    )
  end
end
