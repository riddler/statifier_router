defmodule StatifierRouter.RouteTest do
  use ExUnit.Case, async: true, group: :database

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.TestRepo

  # ADR-0001's example: two bindings on one source, one document, one key.
  @impressions %{
    id: "impressions_to_join",
    source: "ad_events",
    match: "event.kind == 'impression'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "impression",
    data: ["impression_id", "shown_at", "placement"]
  }

  @clicks %{
    id: "clicks_to_join",
    source: "ad_events",
    match: "event.kind == 'click'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "click",
    data: ["impression_id", "clicked_at", "url"]
  }

  @now ~U[2026-09-19 08:00:00.000000Z]
  @no_match [:statifier_router, :route, :no_match]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  defp config(bindings) do
    {:ok, config} = Config.new(repo: TestRepo, delivery: RecordingDelivery, bindings: bindings)
    config
  end

  defp event(message_id, data, overrides \\ %{}) do
    Map.merge(
      %{scope: "7c1e", message_id: message_id, source: "ad_events", data: data},
      overrides
    )
  end

  defp impression do
    event("ad_events/3/1042", %{
      "kind" => "impression",
      "impression_id" => "imp_7f3a",
      "shown_at" => "2026-09-19T07:59:00Z",
      "placement" => "sidebar",
      "campaign" => "fall"
    })
  end

  defp click(data \\ %{}) do
    event(
      "ad_events/3/1107",
      Map.merge(
        %{
          "kind" => "click",
          "impression_id" => "imp_7f3a",
          "clicked_at" => "2026-09-19T08:00:00Z",
          "url" => "https://example.com/offer"
        },
        data
      )
    )
  end

  defp ledger(config), do: TestRepo.all(Config.queryable(config, Ledger))

  describe "route/3 over the impression-and-click bindings" do
    # sabotage: route_binding/4 treated :undefined and false as a hold and
    # went on to the key -> two delivery calls, red; restored, green.
    test "one event against two bindings: one delivery and one no_match" do
      config = config([@impressions, @clicks])

      RecordingDelivery.answer(
        "impressions_to_join",
        {:created_and_delivered, "impressions_to_join", "ex_9k2q"}
      )

      assert StatifierRouter.route(config, impression(), now: @now) ==
               {:ok,
                [
                  {:created_and_delivered, "impressions_to_join", "ex_9k2q"},
                  {:no_match, "clicks_to_join"}
                ]}

      assert_received {:deliver, "impressions_to_join", "imp_7f3a", delivery}

      assert delivery == %{
               name: "impression",
               data: %{
                 "impression_id" => "imp_7f3a",
                 "shown_at" => "2026-09-19T07:59:00Z",
                 "placement" => "sidebar"
               },
               message_id: "ad_events/3/1042",
               scope: "7c1e",
               now: @now
             }

      refute_received {:deliver, _, _, _}
      assert ledger(config) == []
    end

    # sabotage: route/3 prepended outcomes without the final reverse ->
    # the list came back reversed, red; restored, green.
    test "outcomes come back in binding order" do
      assert {:ok,
              [{:no_match, "impressions_to_join"}, {:delivered, "clicks_to_join", "ex_9k2q"}]} =
               StatifierRouter.route(config([@impressions, @clicks]), click(), now: @now)

      assert {:ok,
              [{:delivered, "clicks_to_join", "ex_9k2q"}, {:no_match, "impressions_to_join"}]} =
               StatifierRouter.route(config([@clicks, @impressions]), click(), now: @now)
    end

    # sabotage: no_match/2 skipped :telemetry.execute/3 -> no event
    # received, red; restored, green.
    test "an :undefined match is a no_match, writes nothing and is reported as telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [@no_match])
      on_exit(fn -> :telemetry.detach(ref) end)
      config = config([@impressions, @clicks])
      sparse = event("ad_events/4/0001", %{"impression_id" => "imp_7f3a"})

      assert StatifierRouter.route(config, sparse, now: @now) ==
               {:ok, [{:no_match, "impressions_to_join"}, {:no_match, "clicks_to_join"}]}

      refute_received {:deliver, _, _, _}
      assert ledger(config) == []

      for id <- ["impressions_to_join", "clicks_to_join"] do
        assert_received {@no_match, ^ref, %{count: 1},
                         %{
                           binding_id: ^id,
                           source: "ad_events",
                           scope: "7c1e",
                           message_id: "ad_events/4/0001"
                         }}
      end
    end

    # sabotage: key_refused/5 skipped the ledger insert -> no row, red;
    # restored, green. Second mutation: key_and_deliver/4 delivered with
    # a made-up key on a refusal -> a delivery call, red; restored, green.
    test "a key refusal writes one ledger row and calls the delivery zero times" do
      config = config([@impressions, @clicks])

      no_key =
        event("ad_events/5/0388", %{"kind" => "click", "url" => "https://example.com/offer"})

      assert StatifierRouter.route(config, no_key, now: @now) ==
               {:ok,
                [
                  {:no_match, "impressions_to_join"},
                  {:key_refused, "clicks_to_join", {:key, {:value, :undefined}}}
                ]}

      refute_received {:deliver, _, _, _}

      assert [
               %Ledger{
                 binding_id: "clicks_to_join",
                 message_id: "ad_events/5/0388",
                 scope: "7c1e",
                 outcome: "key_refused",
                 key: nil,
                 execution_id: nil,
                 reason: "{:key, {:value, :undefined}}",
                 inserted_at: @now
               }
             ] = ledger(config)
    end

    # sabotage: the filter in route/3 dropped the enabled check -> the
    # disabled binding contributed an outcome, red; restored, green.
    test "a disabled binding and a binding for another source contribute nothing" do
      config =
        config([
          Map.put(@impressions, :enabled, false),
          %{@clicks | id: "page_clicks", source: "page_events"},
          @clicks
        ])

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:ok, [{:delivered, "clicks_to_join", "ex_9k2q"}]}

      assert StatifierRouter.route(config, event("m1", %{}, %{source: "other"})) == {:ok, []}
    end

    # sabotage: route/3 also filtered on the event's selector equalling the
    # binding's -> the second binding contributed nothing, red; restored,
    # green.
    test "bindings are chosen by source alone; the selector is never read" do
      config =
        config([
          Map.put(@clicks, :selector, %{"topic" => "clicks"}),
          %{@clicks | id: "clicks_audit"} |> Map.put(:selector, %{"topic" => "audit"})
        ])

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:ok,
                [
                  {:delivered, "clicks_to_join", "ex_9k2q"},
                  {:delivered, "clicks_audit", "ex_9k2q"}
                ]}
    end

    # sabotage: key_refused/5 wrote the scope as nil -> the insert raised
    # (the column is not null), red; restored, green. Second mutation:
    # deliver/5 handed the delivery scope: "" -> red; restored, green.
    test "the scope rides with the event into the delivery and the ledger" do
      config = config([@impressions, @clicks])
      other_scope = %{click() | scope: "91ab"}

      assert {:ok, [_no_match, {:delivered, "clicks_to_join", "ex_9k2q"}]} =
               StatifierRouter.route(config, other_scope, now: @now)

      assert_received {:deliver, "clicks_to_join", "imp_7f3a", %{scope: "91ab"}}

      refused = event("ad_events/5/0389", %{"kind" => "click"}, %{scope: "91ab"})
      assert {:ok, [_, {:key_refused, _, _}]} = StatifierRouter.route(config, refused, now: @now)
      assert [%Ledger{scope: "91ab"}] = ledger(config)
    end
  end

  describe "the delivery module's answer" do
    # sabotage: route_next/5's {:error, _} clause continued
    # instead of halting -> the second binding was delivered, red;
    # restored, green.
    test "an {:error, reason} stops the loop; the bindings after it are not attempted" do
      config = config([@clicks, %{@clicks | id: "clicks_audit"}])
      RecordingDelivery.answer("clicks_to_join", {:error, :repo_unavailable})

      assert StatifierRouter.route(config, click(), now: @now) == {:error, :repo_unavailable}
      assert_received {:deliver, "clicks_to_join", _, _}
      refute_received {:deliver, "clicks_audit", _, _}
    end

    # sabotage: deliver/5 wrapped the call in a rescue returning
    # {:error, exception} -> no raise, red; restored, green.
    test "a raise inside a delivery propagates out of route/3" do
      config = config([@clicks])

      RecordingDelivery.answer("clicks_to_join", fn ->
        raise DBConnection.ConnectionError, "lock wait ended"
      end)

      assert_raise DBConnection.ConnectionError, "lock wait ended", fn ->
        StatifierRouter.route(config, click(), now: @now)
      end
    end

    # sabotage: check_answer/3's duplicate clause dropped the ^id pin (any
    # binding id accepted) -> no raise for the foreign id, red; restored,
    # green.
    test "every delivery outcome passes through; any other answer raises" do
      config = config([@clicks])

      for answer <- [
            {:delivered, "clicks_to_join", "ex_9k2q"},
            {:created_and_delivered, "clicks_to_join", "ex_4m8p"},
            {:duplicate, "clicks_to_join"},
            {:dropped, "clicks_to_join", :no_execution},
            {:dropped, "clicks_to_join", :finished}
          ] do
        RecordingDelivery.answer("clicks_to_join", answer)
        assert StatifierRouter.route(config, click(), now: @now) == {:ok, [answer]}
      end

      for answer <- [{:duplicate, "impressions_to_join"}, {:no_match, "clicks_to_join"}, :ok] do
        RecordingDelivery.answer("clicks_to_join", answer)

        assert_raise ArgumentError, ~r/RecordingDelivery.deliver\/4 answered/, fn ->
          StatifierRouter.route(config, click(), now: @now)
        end
      end
    end
  end

  describe "refusal reasons" do
    # sabotage: refusal_reason/2 mapped {:non_boolean, v} to
    # {:match, {:error, v}} -> red on the first assertion; restored, green.
    test "Binding's refusal tags map to ADR-0004's reason terms, one mapping" do
      error = %Predicator.Errors.TypeMismatchError{
        message: "boom",
        expected: :boolean,
        got: :undefined,
        operation: :logical_not
      }

      assert StatifierRouter.refusal_reason(:match, {:non_boolean, "click"}) ==
               {:match, {:value, "click"}}

      assert StatifierRouter.refusal_reason(:match, {:evaluation_error, error}) ==
               {:match, {:error, error}}

      assert StatifierRouter.refusal_reason(:key, {:invalid_key, 42}) == {:key, {:value, 42}}

      assert StatifierRouter.refusal_reason(:key, {:evaluation_error, error}) ==
               {:key, {:error, error}}
    end

    # sabotage: route_binding/4 recorded a refusing match under the :key
    # tag -> red; restored, green.
    test "a refusing match and each refusing key reach the ledger with their reason" do
      config =
        config([
          %{@impressions | id: "kind_as_match", match: "event.kind"},
          %{@impressions | id: "not_missing", match: "not event.missing"},
          %{@clicks | id: "numeric_key", key: "event.count"},
          %{@clicks | id: "arithmetic_key", key: "event.missing + 1"}
        ])

      assert {:ok,
              [
                {:key_refused, "kind_as_match", {:match, {:value, "click"}}},
                {:key_refused, "not_missing",
                 {:match, {:error, %Predicator.Errors.TypeMismatchError{}}}},
                {:key_refused, "numeric_key", {:key, {:value, 3}}},
                {:key_refused, "arithmetic_key",
                 {:key, {:error, %Predicator.Errors.TypeMismatchError{}}}}
              ]} = StatifierRouter.route(config, click(%{"count" => 3}), now: @now)

      refute_received {:deliver, _, _, _}

      reasons = config |> ledger() |> Map.new(&{&1.binding_id, &1.reason})

      assert reasons["kind_as_match"] == ~s({:match, {:value, "click"}})
      assert reasons["numeric_key"] == "{:key, {:value, 3}}"
      assert reasons["not_missing"] =~ "{:match, {:error, %Predicator.Errors.TypeMismatchError{"
      assert reasons["arithmetic_key"] =~ "{:key, {:error, %Predicator.Errors.TypeMismatchError{"
    end
  end

  describe "arguments" do
    # sabotage: validate_event/1 accepted any map -> no error for the
    # missing scope, red; restored, green.
    test "refuses a malformed event before any binding is evaluated" do
      config = config([@clicks])
      no_scope = Map.delete(click(), :scope)

      assert StatifierRouter.route(config, no_scope) == {:error, {:invalid_event, no_scope}}
      assert StatifierRouter.route(config, :click) == {:error, {:invalid_event, :click}}
      refute_received {:deliver, _, _, _}
    end

    # sabotage: fetch_now/1 accepted any :now -> no error for the string,
    # red; restored, green.
    test "refuses a malformed option" do
      config = config([@clicks])

      assert StatifierRouter.route(config, click(), now: "now") ==
               {:error, {:invalid_value, :now, "now"}}

      assert StatifierRouter.route(config, click(), at: @now) == {:error, {:unknown_key, :at}}
      assert StatifierRouter.route(config, click(), [:now]) == {:error, {:invalid_opts, [:now]}}
      refute_received {:deliver, _, _, _}
    end

    # sabotage: fetch_now/1 kept the caller's precision -> the second-
    # precision time failed to dump into the usec column, red; restored,
    # green.
    test "now defaults to the current time and is written at microsecond precision" do
      config = config([@clicks])
      before = DateTime.utc_now()

      assert {:ok, [_]} = StatifierRouter.route(config, click())
      assert_received {:deliver, _, _, %{now: now}}
      assert DateTime.compare(now, before) != :lt

      refused = event("ad_events/5/0390", %{"kind" => "click"})
      assert {:ok, _} = StatifierRouter.route(config, refused, now: ~U[2026-09-19 08:00:00Z])
      assert [%Ledger{inserted_at: ~U[2026-09-19 08:00:00.000000Z]}] = ledger(config)
    end
  end
end
