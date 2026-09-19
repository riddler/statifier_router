defmodule StatifierRouter.CreateModesTest do
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Addresses
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Delivery
  alias StatifierRouter.Schema
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-19 08:00:00.000000Z]
  @hour 3_600_000
  @horizon_ms 259_200_000
  @expires ~U[2026-09-22 08:00:00.000000Z]
  @discarded [:statifier_persistence, :execution, :discarded]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "a :never binding" do
    # sabotage: absent/4 sent a :never binding to insert_or_existing/4 ->
    # the click created an execution, red; restored, green. Second
    # mutation: claimed/4 went straight to by_mode/4 for a :never binding,
    # skipping the claim -> the pair had no dedupe row, red; restored,
    # green.
    test "a click before any impression is dropped: no_execution, creating nothing, and writes its dedupe row" do
      config = config(self(), bindings: [impressions(), clicks(%{create: :never})])

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:ok,
                [{:no_match, "impressions_to_join"}, {:dropped, "clicks_to_join", :no_execution}]}

      refute_received {:resolved, _, _}
      assert executions() == 0
      assert input_rows() == 0
      assert addresses(config) == []

      assert [
               %Ledger{
                 binding_id: "clicks_to_join",
                 message_id: "ad_events/3/1107",
                 scope: "7c1e",
                 outcome: "dropped: no_execution",
                 key: "imp_7f3a",
                 execution_id: nil,
                 reason: nil,
                 inserted_at: @now
               }
             ] = ledger(config)

      assert dedupe_rows(config) == [{"clicks_to_join", "ad_events/3/1107", @expires}]

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:ok, [{:no_match, "impressions_to_join"}, {:duplicate, "clicks_to_join"}]}

      assert ["dropped: no_execution", "duplicate"] = Enum.map(ledger(config), & &1.outcome)
    end

    # sabotage: by_mode/4 answered absent/4 for every :never binding,
    # row or no row -> the first click was dropped: no_execution, red;
    # restored, green. Second mutation: finished/6 deleted the address row after
    # stamping it -> the row was gone after the late click, red; restored,
    # green.
    test "a click is delivered to an existing execution; a late click after it finished is dropped: finished and the row stays" do
      config = config(self(), bindings: [impressions(), clicks(%{create: :never})])

      {:ok, [{:created_and_delivered, _, execution_id}, _]} =
        StatifierRouter.route(config, impression(), now: @now)

      assert {:ok, [_, {:delivered, "clicks_to_join", ^execution_id}]} =
               StatifierRouter.route(config, click(), now: @now)

      assert StatifierRouter.route(config, click("ad_events/3/1311"), now: @now) ==
               {:ok,
                [{:no_match, "impressions_to_join"}, {:dropped, "clicks_to_join", :finished}]}

      assert [
               %Address{
                 key: "imp_7f3a",
                 execution_id: ^execution_id,
                 terminal_seen_at: @now
               }
             ] = addresses(config)

      assert executions() == 1
      assert inputs(config, execution_id) == [{0, "step", "impression"}, {1, "step", "click"}]

      assert %Ledger{
               message_id: "ad_events/3/1311",
               outcome: "dropped: finished",
               execution_id: ^execution_id
             } = List.last(ledger(config))
    end
  end

  describe "an :always_new binding" do
    # sabotage: by_mode/4 read the address for an :always_new binding as
    # for :if_absent -> the second impression was delivered to the first
    # execution, red; restored, green. Second mutation: create/6 inserted
    # an address row for the minted id -> addresses were written, red;
    # restored, green.
    test "two impressions of one key create two executions and write no address row" do
      config = config(self(), bindings: [impressions(%{create: :always_new})])

      assert {:ok, [{:created_and_delivered, "impressions_to_join", first}]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert {:ok, [{:created_and_delivered, "impressions_to_join", second}]} =
               StatifierRouter.route(config, impression("ad_events/3/1043", "imp_7f3a"),
                 now: @now
               )

      assert first != second
      assert executions() == 2
      assert addresses(config) == []
      assert inputs(config, first) == [{0, "step", "impression"}]
      assert inputs(config, second) == [{0, "step", "impression"}]

      assert [
               %Ledger{outcome: "created_and_delivered", key: "imp_7f3a", execution_id: ^first},
               %Ledger{outcome: "created_and_delivered", key: "imp_7f3a", execution_id: ^second}
             ] = ledger(config)

      assert StatifierRouter.route(config, impression(), now: @now) ==
               {:ok, [{:duplicate, "impressions_to_join"}]}

      assert executions() == 2
    end

    # sabotage: create/6 dropped its terminal check and stepped the
    # execution create/4 returned terminal -> step/5 was called and
    # reported a discard, red; restored, green.
    test "an execution created already terminal is dropped: finished with its id, unstepped, and no row" do
      ref = :telemetry_test.attach_event_handlers(self(), [@discarded])
      on_exit(fn -> :telemetry.detach(ref) end)

      config = config(self(), bindings: [])
      binding = built(impressions(%{create: :always_new, document: "instant_join"}))

      delivery = %{
        name: "impression",
        data: %{"impression_id" => "imp_7f3a"},
        message_id: "ad_events/3/1042",
        scope: "7c1e",
        now: @now
      }

      assert Delivery.deliver(config, binding, "imp_7f3a", delivery) ==
               {:dropped, "impressions_to_join", :finished}

      assert addresses(config) == []
      assert executions() == 1
      assert input_rows() == 0

      assert [%Ledger{outcome: "dropped: finished", execution_id: execution_id}] = ledger(config)
      assert "ex_" <> _ = execution_id
      refute_received {@discarded, ^ref, _, %{execution_id: ^execution_id}}
    end
  end

  describe "the claim is the delivery's first write" do
    # sabotage: claimed/4 ran by_mode/4 before Dedupe.claim/4 -> the
    # redelivered click found no address row, created a new execution and
    # wrote a row, red; restored, green.
    test "a duplicate whose address row was reaped while its dedupe row is unexpired leaves no address row" do
      config = config(self())

      {:ok, [{:created_and_delivered, _, execution_id}, _]} =
        StatifierRouter.route(config, impression(), now: @now)

      {:ok, [_, {:delivered, _, ^execution_id}]} =
        StatifierRouter.route(config, click(), now: @now)

      # No binding names the document, so its horizon is zero and the
      # finished execution's row goes at this reap.
      assert Addresses.reap(config, [], now: @now) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert addresses(config) == []

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:ok, [{:no_match, "impressions_to_join"}, {:duplicate, "clicks_to_join"}]}

      assert addresses(config) == []
      assert executions() == 1
    end
  end

  describe "Addresses.reap/2" do
    # sabotage: due?/3 answered true for every terminal row -> the row
    # inside the horizon was deleted, red; restored,
    # green. Second mutation: due?/3 compared strictly (:lt) -> the row
    # at exactly its horizon was kept, red; restored, green.
    test "keeps a finished execution's row inside the horizon and removes it once the horizon has elapsed" do
      config = config(self())
      finished_execution(config, "imp_7f3a")

      # The first reap is the first to see the execution terminal.
      assert Addresses.reap(config, config.bindings, now: @now) ==
               {:ok, %{stamped: 1, deleted: 0, next: nil}}

      assert [%Address{terminal_seen_at: @now}] = addresses(config)

      just_inside = DateTime.add(@now, @horizon_ms - 1, :millisecond)

      assert Addresses.reap(config, config.bindings, now: just_inside) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert [%Address{terminal_seen_at: @now}] = addresses(config)

      assert Addresses.reap(config, config.bindings, now: @expires) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert addresses(config) == []
      assert executions() == 1
    end

    # sabotage: terminal/3 treated every status as terminal -> the active
    # execution's row was stamped, red; restored, green. (A row already
    # stamped is never in stamp/3's list, so its is_nil guard, kept for a
    # delivery stamping the row between the read and the write, stayed
    # green when dropped: this test pins the read, not that guard.)
    test "stamps a row first seen terminal, leaves an active one alone and never moves a stamp" do
      config = config(self())
      finished_execution(config, "imp_done")

      {:ok, [{:created_and_delivered, _, active}, _]} =
        StatifierRouter.route(config, impression("ad_events/3/2001", "imp_live"), now: @now)

      finished_execution(config, "imp_seen")

      {:ok, [_, {:dropped, _, :finished}]} =
        StatifierRouter.route(config, click("ad_events/3/2002", "imp_seen"), now: @now)

      later = DateTime.add(@now, @hour, :millisecond)

      assert Addresses.reap(config, config.bindings, now: later) ==
               {:ok, %{stamped: 1, deleted: 0, next: nil}}

      assert %{
               "imp_done" => %Address{terminal_seen_at: ^later},
               "imp_live" => %Address{execution_id: ^active, terminal_seen_at: nil},
               "imp_seen" => %Address{terminal_seen_at: @now}
             } = Map.new(addresses(config), &{&1.key, &1})

      assert inputs(config, active) == [{0, "step", "impression"}]
    end

    # sabotage: horizons/1 ignored enabled -> the disabled binding's
    # horizon kept the row, red; restored, green.
    test "a document no enabled binding names has a horizon of zero: its finished rows go at the next reap" do
      config = config(self())
      finished_execution(config, "imp_7f3a")
      disabled = for binding <- config.bindings, do: %{binding | enabled: false}

      assert Addresses.reap(config, disabled, now: @now) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert addresses(config) == []

      {:ok, [{:created_and_delivered, _, fresh}, _]} =
        StatifierRouter.route(config, impression("ad_events/3/3001", "imp_7f3a"), now: @now)

      assert [%Address{key: "imp_7f3a", execution_id: ^fresh}] = addresses(config)
    end

    # sabotage: horizons/1 kept the shortest horizon (min) -> the row was
    # deleted at two hours, red; restored, green.
    test "the horizon is the longest of any enabled binding naming the document" do
      config = config(self())
      finished_execution(config, "imp_7f3a")
      [impressions, clicks] = config.bindings

      bindings = [
        %{impressions | dedupe: %{by: :message_id, horizon_ms: @hour}},
        %{clicks | dedupe: %{by: :message_id, horizon_ms: 3 * @hour}},
        built(impressions(%{id: "other", document: "other_join", dedupe: long()}))
      ]

      {:ok, %{stamped: 1}} = Addresses.reap(config, bindings, now: @now)

      assert Addresses.reap(config, bindings, now: DateTime.add(@now, 2 * @hour, :millisecond)) ==
               {:ok, %{stamped: 0, deleted: 0, next: nil}}

      assert Addresses.reap(config, bindings, now: DateTime.add(@now, 3 * @hour, :millisecond)) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}
    end

    # sabotage: examine/3 ignored :limit -> the first call reached the
    # finished row and deleted it, red; restored, green. Second mutation:
    # examine/3 ignored :after -> the second call re-read the two live rows
    # and deleted nothing, red; restored, green.
    test "examines at most :limit rows per call and continues from :after" do
      config = config(self())

      for {message_id, id} <- [{"ad_events/3/4001", "imp_a"}, {"ad_events/3/4002", "imp_b"}] do
        {:ok, _} = StatifierRouter.route(config, impression(message_id, id), now: @now)
      end

      finished_execution(config, "imp_c")

      assert {:ok, %{stamped: 0, deleted: 0, next: next}} =
               Addresses.reap(config, [], now: @now, limit: 2)

      assert is_integer(next)
      assert length(addresses(config)) == 3

      assert Addresses.reap(config, [], now: @now, limit: 2, after: next) ==
               {:ok, %{stamped: 0, deleted: 1, next: nil}}

      assert ["imp_a", "imp_b"] = addresses(config) |> Enum.map(& &1.key) |> Enum.sort()
    end

    # sabotage: terminal_rows/3 skipped a row whose read failed -> the due
    # row before it was deleted and the call answered :ok, red; restored,
    # green.
    test "a failed status read ends the call before it writes anything" do
      config = config(self())
      finished_execution(config, "imp_7f3a")
      {:ok, %{stamped: 1}} = Addresses.reap(config, config.bindings, now: @now)

      orphan = %Address{
        scope: "7c1e",
        document: "impression_click_join",
        key: "imp_orphan",
        execution_id: "ex_missing",
        inserted_at: @now
      }

      TestRepo.insert!(Config.put_meta(config, orphan))

      assert Addresses.reap(config, [], now: @now) == {:error, :execution_not_found}
      assert length(addresses(config)) == 2
    end

    # sabotage: options/1 dropped reject_unknown -> the unknown option was
    # accepted, red; restored, green.
    test "refuses malformed options" do
      config = config(self())

      assert Addresses.reap(config, [], cursor: 1) == {:error, {:unknown_key, :cursor}}
      assert Addresses.reap(config, [], [:now]) == {:error, {:invalid_opts, [:now]}}
      assert Addresses.reap(config, [], limit: 0) == {:error, {:invalid_value, :limit, 0}}
      assert Addresses.reap(config, [], after: -1) == {:error, {:invalid_value, :after, -1}}

      assert Addresses.reap(config, [], now: ~N[2026-09-19 08:00:00]) ==
               {:error, {:invalid_value, :now, ~N[2026-09-19 08:00:00]}}

      assert {:ok, %{stamped: 0, deleted: 0, next: nil}} = Addresses.reap(config, [])
    end
  end

  # An impression and its click routed through the default :if_absent
  # bindings: the click ends the join chart, so the execution is completed
  # and its address row is not yet stamped.
  defp finished_execution(config, impression_id) do
    {:ok, [{:created_and_delivered, _, execution_id}, _]} =
      StatifierRouter.route(config, impression("imp/#{impression_id}", impression_id), now: @now)

    {:ok, [_, {:delivered, _, ^execution_id}]} =
      StatifierRouter.route(config, click("click/#{impression_id}", impression_id), now: @now)

    execution_id
  end

  defp impression(message_id, impression_id) do
    event(message_id, %{
      "kind" => "impression",
      "impression_id" => impression_id,
      "placement" => "sidebar"
    })
  end

  defp click(message_id, impression_id) do
    event(message_id, %{"kind" => "click", "impression_id" => impression_id})
  end

  defp impressions(overrides \\ %{}), do: Map.merge(Enum.at(bindings(), 0), overrides)
  defp clicks(overrides), do: Map.merge(Enum.at(bindings(), 1), overrides)

  defp built(attrs) do
    {:ok, binding} = Binding.new(attrs)
    binding
  end

  defp long, do: %{by: :message_id, horizon_ms: 100 * @hour}

  defp dedupe_rows(config) do
    TestRepo.all(
      from(d in Config.queryable(config, Schema.Dedupe),
        order_by: [d.binding_id, d.message_id],
        select: {d.binding_id, d.message_id, d.expires_at}
      )
    )
  end
end
