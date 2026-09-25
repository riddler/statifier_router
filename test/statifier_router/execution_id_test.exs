defmodule StatifierRouter.ExecutionIdTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.Storage
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger}
  alias StatifierRouter.TestRepo

  # ADR-0002, the Amendment of 2026-09-25: a configuration's `:execution_id`
  # mints the id of every execution the delivery creates, from the
  # delivery's scope, the document and the key. `trip_` is a fictional
  # prefix, the kind a host would choose for its own ids.

  @now ~U[2026-09-25 08:00:00.000000Z]

  defmodule TripIds do
    @moduledoc false
    def execution_id(_scope, document, key), do: "trip_#{document}_#{key}"
  end

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  # Reports each call to `pid` and answers a fresh `trip_` id.
  defp trip_ids(pid) do
    fn scope, document, key ->
      send(pid, {:minted, scope, document, key})
      "trip_" <> Integer.to_string(System.unique_integer([:positive]))
    end
  end

  defp parcel_config(opts), do: config(self(), [bindings: parcel_bindings()] ++ opts)

  defp scan(message_id, kind), do: parcel_scan(message_id, kind)

  defp dedupe_rows(config), do: TestRepo.all(StatifierRouter.Config.queryable(config, Dedupe))

  describe "an :if_absent binding" do
    # sabotage: insert_or_existing/4 minted with the default UXID whatever
    # the configuration -> the outcome carried an ex_ id, red; restored,
    # green. Second mutation: mint_execution_id/4 handed the
    # callback the binding id in place of the document -> the minted
    # message named "loaded_scans", red; restored, green.
    test "the host's id is the one on the address row, the execution and the ledger" do
      config = parcel_config(execution_id: trip_ids(self()))

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_" <> _ = execution_id}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert_received {:minted, "7c1e", "parcel_route", "pcl_4821"}

      assert [%Address{scope: "7c1e", document: "parcel_route", key: "pcl_4821"} = row] =
               addresses(config)

      assert row.execution_id == execution_id

      assert [%Ledger{outcome: "created_and_delivered", execution_id: ^execution_id}] =
               ledger(config)

      assert {:ok, %{execution_id: ^execution_id}} =
               Storage.fetch_execution(config.store, execution_id)

      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: duplicate/4 minted an id before writing its ledger row ->
    # the callback was called for the duplicate, red; restored, green.
    # Second mutation: existing/5 stepped a freshly minted id in place of
    # the row's -> {:error, :execution_not_found}, red; restored, green.
    test "a duplicate and a later delivery mint nothing, and the host's id stands" do
      config = parcel_config(execution_id: trip_ids(self()))

      assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert_received {:minted, _, _, _}

      # The same message again: the dedupe claim catches it, and no id is
      # minted for it.
      assert {:ok, [{:duplicate, "loaded_scans"}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      # A new message to the same address steps the execution the host's
      # id names.
      assert {:ok, [_, {:delivered, "delivered_scans", ^execution_id}]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0002", "delivered"), now: @now)

      refute_received {:minted, _, _, _}

      assert [%Address{execution_id: ^execution_id}] = addresses(config)

      # The dedupe table carries no execution id; its rows are the two
      # pairs claimed, and the duplicate wrote none of its own.
      assert [
               %Dedupe{binding_id: "delivered_scans", message_id: "parcel_scans/1/0002"},
               %Dedupe{binding_id: "loaded_scans", message_id: "parcel_scans/1/0001"}
             ] = Enum.sort_by(dedupe_rows(config), & &1.binding_id)

      # A duplicate's ledger row names no execution (ADR-0004, section 4).
      assert [
               %Ledger{outcome: "created_and_delivered", execution_id: ^execution_id},
               %Ledger{outcome: "duplicate", execution_id: nil},
               %Ledger{outcome: "delivered", execution_id: ^execution_id}
             ] = ledger(config)
    end

    # sabotage: mint_execution_id/4 called the module's create/3 in place
    # of execution_id/3 -> UndefinedFunctionError, red; restored, green.
    test "a module is called as module.execution_id/3" do
      config = parcel_config(execution_id: TripIds)

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_parcel_route_pcl_4821"}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert [%Address{execution_id: "trip_parcel_route_pcl_4821"}] = addresses(config)
    end
  end

  describe "an :always_new binding" do
    # sabotage: by_mode/4's :always_new clause minted with the default
    # UXID -> the created execution carried an ex_ id, red; restored,
    # green.
    test "every create is minted through the callback, and no address row is written" do
      bindings = Enum.map(parcel_bindings(), &Map.put(&1, :create, :always_new))
      config = config(self(), bindings: bindings, execution_id: trip_ids(self()))

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_" <> _ = first}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_" <> _ = second}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0002", "loaded"), now: @now)

      assert first != second
      assert_received {:minted, "7c1e", "parcel_route", "pcl_4821"}
      assert_received {:minted, "7c1e", "parcel_route", "pcl_4821"}
      assert addresses(config) == []

      assert [%Ledger{execution_id: ^first}, %Ledger{execution_id: ^second}] = ledger(config)
    end
  end

  describe "an answer the delivery cannot use" do
    # sabotage: mint_execution_id/4's guard accepted any binary -> the
    # empty string passed as an id and no ArgumentError was raised, red;
    # restored, green. Second mutation: the guard dropped is_binary/1 ->
    # a non-string answer passed as an id, red; restored, green.
    test "an answer that is not a non-empty string raises and writes nothing" do
      for answer <- ["", :trip, 42, nil] do
        config = parcel_config(execution_id: fn _scope, _document, _key -> answer end)

        assert_raise ArgumentError, ~r/:execution_id answered/, fn ->
          StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)
        end
      end

      assert executions() == 0
    end

    # sabotage: a rescue around the callback call in mint_execution_id/4,
    # answering nil -> the raise became an ArgumentError, red; restored,
    # green.
    test "a raise from the callback propagates as raised" do
      config =
        parcel_config(execution_id: fn _scope, _document, _key -> raise "no trip ids today" end)

      assert_raise RuntimeError, "no trip ids today", fn ->
        StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)
      end
    end

    # sabotage: guarded/5's error arm released the savepoint in place of
    # rolling back to it -> the aborted transaction raised in place of the
    # refusal, red; restored, green.
    test "an id statifier_persistence already holds is refused and the delivery rolls back" do
      config = parcel_config(execution_id: fn _scope, _document, _key -> "trip_reused" end)

      assert {:ok, [{:created_and_delivered, "loaded_scans", "trip_reused"}, _]} =
               StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

      # A second address answered the same id: create/4 refuses it.
      other = %{
        scan("parcel_scans/1/0002", "loaded")
        | data: %{"kind" => "loaded", "parcel_id" => "pcl_5930"}
      }

      assert StatifierRouter.route(config, other, now: @now) == {:error, :execution_exists}

      assert [%Address{key: "pcl_4821", execution_id: "trip_reused"}] = addresses(config)
      assert [%Ledger{message_id: "parcel_scans/1/0001"}] = ledger(config)
      assert executions() == 1
    end
  end

  # sabotage: mint_execution_id/4's nil clause minted with the prefix xx
  # -> red; restored, green.
  test "left out, the id is a UXID with the prefix ex, as before" do
    config = parcel_config([])

    assert {:ok, [{:created_and_delivered, "loaded_scans", "ex_" <> _ = execution_id}, _]} =
             StatifierRouter.route(config, scan("parcel_scans/1/0001", "loaded"), now: @now)

    assert [%Address{execution_id: ^execution_id}] = addresses(config)
    assert [%Ledger{execution_id: ^execution_id}] = ledger(config)
  end
end
