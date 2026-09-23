defmodule StatifierRouter.DedupeTest do
  use ExUnit.Case, async: true, group: :database

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Dedupe
  alias StatifierRouter.Schema
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-19 08:00:00.000000Z]
  @horizon_ms 259_200_000
  @expires ~U[2026-09-22 08:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    %{config: config(self())}
  end

  defp dedupe_rows(config) do
    TestRepo.all(
      from(d in Config.queryable(config, Schema.Dedupe),
        order_by: [d.binding_id, d.message_id],
        select: {d.binding_id, d.message_id, d.expires_at}
      )
    )
  end

  defp built_binding(overrides \\ %{}) do
    {:ok, binding} = Binding.new(Map.merge(hd(bindings()), overrides))
    binding
  end

  defp claim(config, binding, message_id, now) do
    TestRepo.transaction(fn -> Dedupe.claim(config, binding, message_id, now) end)
  end

  describe "a delivery" do
    # sabotage: if_absent/4 went straight to the address, skipping the
    # claim -> the second route delivered the impression again, red;
    # restored, green. Second mutation: duplicate/4 wrote no ledger row ->
    # the ledger held one row, red; restored, green.
    test "the same message twice: created_and_delivered, then duplicate, with one input row",
         %{config: config} do
      assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert StatifierRouter.route(config, impression(), now: @now) ==
               {:ok, [{:duplicate, "impressions_to_join"}, {:no_match, "clicks_to_join"}]}

      assert input_rows() == 1
      assert inputs(config, execution_id) == [{0, "step", "impression"}]
      assert executions() == 1

      assert [
               %Ledger{outcome: "created_and_delivered", execution_id: ^execution_id},
               %Ledger{
                 binding_id: "impressions_to_join",
                 message_id: "ad_events/3/1042",
                 scope: "7c1e",
                 outcome: "duplicate",
                 key: "imp_7f3a",
                 execution_id: nil,
                 reason: nil,
                 inserted_at: @now
               }
             ] = ledger(config)

      assert dedupe_rows(config) == [{"impressions_to_join", "ad_events/3/1042", @expires}]
    end

    # sabotage: claim/4 wrote every row under one fixed binding id -> the
    # second binding's claim was a duplicate, red; restored, green.
    test "two bindings, one message: two claims, two deliveries" do
      by_placement = %{
        hd(bindings())
        | id: "impressions_by_placement",
          key: "event.placement"
      }

      config = config(self(), bindings: [hd(bindings()), by_placement])

      assert {:ok,
              [
                {:created_and_delivered, "impressions_to_join", first},
                {:created_and_delivered, "impressions_by_placement", second}
              ]} = StatifierRouter.route(config, impression(), now: @now)

      assert first != second
      assert input_rows() == 2

      assert dedupe_rows(config) == [
               {"impressions_by_placement", "ad_events/3/1042", @expires},
               {"impressions_to_join", "ad_events/3/1042", @expires}
             ]

      assert StatifierRouter.route(config, impression(), now: @now) ==
               {:ok,
                [{:duplicate, "impressions_to_join"}, {:duplicate, "impressions_by_placement"}]}

      assert input_rows() == 2
    end

    # sabotage: claim/4's conflict update dropped its expiry condition
    # (every conflict replaced the row) -> the message inside the horizon
    # was delivered again, red; restored, green. Second mutation: the
    # condition compared with <= -> the message at exactly expires_at was
    # delivered, red; restored, green.
    test "an expired row counts as absent before it is reaped" do
      config = config(self(), bindings: [impression_binding(%{dedupe: short()})])
      at_expiry = DateTime.add(@now, 1_000, :millisecond)
      after_expiry = DateTime.add(at_expiry, 1, :microsecond)

      assert {:ok, [{:created_and_delivered, _, execution_id}]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert StatifierRouter.route(config, impression(), now: at_expiry) ==
               {:ok, [{:duplicate, "impressions_to_join"}]}

      assert {:ok, [{:delivered, "impressions_to_join", ^execution_id}]} =
               StatifierRouter.route(config, impression(), now: after_expiry)

      assert inputs(config, execution_id) == [
               {0, "step", "impression"},
               {1, "step", "impression"}
             ]

      expires_again = DateTime.add(after_expiry, 1_000, :millisecond)
      assert dedupe_rows(config) == [{"impressions_to_join", "ad_events/3/1042", expires_again}]

      assert ["created_and_delivered", "duplicate", "delivered"] =
               Enum.map(ledger(config), & &1.outcome)
    end

    # sabotage: deliver/4 claimed before opening its transaction, outside
    # it -> the failed delivery left a row and the retry was a duplicate,
    # red; restored, green.
    test "a delivery that rolls back leaves no row, and its redelivery is attempted again",
         %{config: config} do
      failing =
        config(self(),
          resolver: fn _scope, _document -> {:error, :unknown_document} end,
          bindings: [impression_binding()]
        )

      assert StatifierRouter.route(failing, impression(), now: @now) ==
               {:error, {:unresolved_document, "impression_click_join", :unknown_document}}

      assert dedupe_rows(config) == []
      assert ledger(config) == []

      config = config(self(), bindings: [impression_binding()])

      assert {:ok, [{:created_and_delivered, "impressions_to_join", _}]} =
               StatifierRouter.route(config, impression(), now: @now)
    end

    # sabotage: finished/5 deleted the pair's dedupe row before writing
    # its ledger row -> the drop's pair had no row, red; restored, green.
    test "a drop writes its dedupe row too", %{config: config} do
      {:ok, _} = StatifierRouter.route(config, impression(), now: @now)
      {:ok, _} = StatifierRouter.route(config, click(), now: @now)

      assert {:ok, [_, {:dropped, "clicks_to_join", :finished}]} =
               StatifierRouter.route(config, click("ad_events/3/1311"), now: @now)

      assert {"clicks_to_join", "ad_events/3/1311", @expires} in dedupe_rows(config)

      assert StatifierRouter.route(config, click("ad_events/3/1311"), now: @now) ==
               {:ok, [{:no_match, "impressions_to_join"}, {:duplicate, "clicks_to_join"}]}
    end
  end

  describe "claim/4" do
    # sabotage: claim/4 set expires_at to now -> the row's expiry was
    # @now, red; restored, green.
    test "writes the pair's row with the binding's horizon, then answers duplicate",
         %{config: config} do
      assert claim(config, built_binding(), "ad_events/3/1042", @now) == {:ok, :new}
      assert claim(config, built_binding(), "ad_events/3/1042", @now) == {:ok, :duplicate}

      assert dedupe_rows(config) == [
               {"impressions_to_join", "ad_events/3/1042",
                DateTime.add(@now, @horizon_ms, :millisecond)}
             ]
    end
  end

  describe "under a table prefix and a Postgres schema" do
    # sabotage: claim/4's conflict update read the default table (from the
    # schema module, not the configuration) -> Ecto refused the insert for
    # its mismatched source, red; restored, green. Second mutation: reap/2
    # read the default table -> the count was 0, red; restored, green.
    test "claim/4 and reap/2 write and read the configured table", %{config: config} do
      SQL.query!(TestRepo, ~s(CREATE SCHEMA "claims_elsewhere"))

      SQL.query!(
        TestRepo,
        ~s(CREATE TABLE "claims_elsewhere"."kx_dedupe" ) <>
          "(LIKE statifier_router_dedupe INCLUDING ALL)"
      )

      elsewhere = %{config | table_prefix: "kx_", prefix: "claims_elsewhere"}
      short = built_binding(%{dedupe: short()})
      later = DateTime.add(@now, 2, :second)

      assert claim(elsewhere, short, "ad_events/3/1042", @now) == {:ok, :new}
      assert claim(elsewhere, short, "ad_events/3/1042", @now) == {:ok, :duplicate}
      assert claim(elsewhere, short, "ad_events/3/1042", later) == {:ok, :new}
      assert claim(elsewhere, short, "ad_events/3/1107", @now) == {:ok, :new}

      assert dedupe_rows(config) == []

      assert Dedupe.reap(elsewhere, later) == {:ok, 1}

      assert dedupe_rows(elsewhere) == [
               {"impressions_to_join", "ad_events/3/1042", DateTime.add(later, 1, :second)}
             ]
    end
  end

  describe "reap/2" do
    # sabotage: reap/2 deleted with <= -> the row expiring exactly at the
    # reap time went too and the count was 2, red; restored, green.
    # Second mutation: reap/2 dropped its where clause -> every row went
    # and the count was 3, red; restored, green.
    test "removes only expired rows and returns the count", %{config: config} do
      short = built_binding(%{dedupe: short()})
      {:ok, :new} = claim(config, short, "ad_events/3/1001", @now)
      {:ok, :new} = claim(config, short, "ad_events/3/1002", DateTime.add(@now, 1, :second))
      {:ok, :new} = claim(config, built_binding(), "ad_events/3/1003", @now)

      reap_at = DateTime.add(@now, 2, :second)

      assert TestRepo.transaction(fn -> Dedupe.reap(config, reap_at) end) == {:ok, {:ok, 1}}

      assert [
               {"impressions_to_join", "ad_events/3/1002", ^reap_at},
               {"impressions_to_join", "ad_events/3/1003", @expires}
             ] = dedupe_rows(config)

      assert Dedupe.reap(config, reap_at) == {:ok, 0}
    end
  end

  describe "route/3" do
    # sabotage: validate_event/1 lost its message id clause -> the empty
    # id was delivered and nil answered {:invalid_event, _}, red; restored,
    # green.
    test "refuses a nil or empty message id before any binding is evaluated",
         %{config: config} do
      for message_id <- [nil, ""] do
        event = %{impression() | message_id: message_id}
        assert StatifierRouter.route(config, event, now: @now) == {:error, :no_message_id}
      end

      assert dedupe_rows(config) == []
      assert ledger(config) == []
      assert executions() == 0
    end
  end

  defp short, do: %{by: :message_id, horizon_ms: 1_000}

  defp impression_binding(overrides \\ %{}), do: Map.merge(hd(bindings()), overrides)
end
