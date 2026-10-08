defmodule StatifierRouter.WebhookTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures,
    only: [bindings: 0, config: 1, executions: 0, ledger: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.TestRepo
  alias StatifierRouter.Webhook

  doctest StatifierRouter.Webhook

  # The bytes a provider posts, and their lowercase hex SHA-256. The digest
  # is written out rather than computed here: a test that recomputes it with
  # the same two calls the module makes would agree with any digest the
  # module chose.
  @body ~s({"kind":"impression","impression_id":"imp_7f3a","placement":"sidebar"})
  @body_sha "7ededb5bbe66b9ca5bda0f609018aeeafc5a25a222aa7db88873fdfdb70b5741"

  @data %{"kind" => "impression", "impression_id" => "imp_7f3a", "placement" => "sidebar"}
  @now ~U[2026-09-19 08:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        scope: "7c1e",
        source: "ad_events",
        selector: %{"path" => "/webhooks/ad_events"},
        raw_body: @body,
        data: @data,
        provider_id: nil
      },
      overrides
    )
  end

  defp recording_config do
    {:ok, config} = Config.new(repo: TestRepo, delivery: RecordingDelivery, bindings: bindings())
    config
  end

  describe "the message id" do
    # sabotage: message_id/2's provider clause deleted, so every request
    # fell to the hash -> this test red on the delivered message id;
    # restored, green.
    test "is the provider's event id when it sends a non-empty one" do
      config = recording_config()

      assert {:ok, [{:delivered, "impressions_to_join", _}, {:no_match, "clicks_to_join"}]} =
               Webhook.handle(config, request(%{provider_id: "evt_2f9c"}), now: @now)

      assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: "evt_2f9c"}}
    end

    # sabotage: message_id/2's provider clause guarded on is_binary alone,
    # so an empty provider id won -> this test red; restored, green.
    # Second mutation: Base.encode16/2 called without `case: :lower` -> this
    # test and the two below that assert the digest red, three in all;
    # restored, green.
    test "falls to the lowercase hex SHA-256 of the raw body when it does not" do
      assert @body_sha =~ ~r/\A[0-9a-f]{64}\z/

      for provider_id <- [%{provider_id: nil}, %{provider_id: ""}] do
        config = recording_config()

        assert {:ok, [{:delivered, "impressions_to_join", _}, _no_match]} =
                 Webhook.handle(config, request(provider_id), now: @now)

        assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: @body_sha}}
      end

      config = recording_config()
      without_key = Map.delete(request(), :provider_id)

      assert {:ok, [{:delivered, "impressions_to_join", _}, _no_match]} =
               Webhook.handle(config, without_key, now: @now)

      assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: @body_sha}}
    end

    # Pins the answer to a request that carries a binary :raw_body across the
    # four provider ids: a non-empty string wins, and nil, "" and a non-string
    # all fall to the body's digest. The non-string case had no test before
    # :raw_body became optional.
    # sabotage: message_id/1's binary-body clause dropped the provider id and
    # always hashed -> the "evt_2f9c" row red on its message id, and the
    # provider-id test above with it; restored, green. Second mutation:
    # message_id/2's provider clause guarded on `provider_id not in [nil, ""]`
    # rather than is_binary -> the 4071 row red, its integer handed on as the
    # message id; restored, green.
    test "a request carrying a binary raw body is answered as before" do
      for {provider_id, message_id} <- [
            {"evt_2f9c", "evt_2f9c"},
            {nil, @body_sha},
            {"", @body_sha},
            {4071, @body_sha}
          ] do
        config = recording_config()

        assert {:ok, [{:delivered, "impressions_to_join", _}, {:no_match, "clicks_to_join"}]} =
                 Webhook.handle(config, request(%{provider_id: provider_id}), now: @now)

        assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: ^message_id}}
      end
    end

    # sabotage: message_id/1's provider-id-alone clause deleted, so a request
    # without :raw_body fell to the refusal -> this test red on the
    # {:invalid_request, _} answer; restored, green.
    test "is the provider id alone when the request carries no raw body" do
      config = config(self())
      without_body = Map.delete(request(%{provider_id: "evt_5b1d"}), :raw_body)

      assert {:ok, [{:created_and_delivered, "impressions_to_join", _}, _no_match]} =
               Webhook.handle(config, without_body, now: @now)

      assert {:ok, [{:duplicate, "impressions_to_join"}, _no_match]} =
               Webhook.handle(config, without_body, now: @now)

      assert Enum.map(ledger(config), &{&1.outcome, &1.message_id}) == [
               {"created_and_delivered", "evt_5b1d"},
               {"duplicate", "evt_5b1d"}
             ]
    end
  end

  describe "handle/3" do
    # sabotage: message_id/2's hash clause answered fresh random bytes
    # rather than the body's digest, so the second post was no duplicate
    # -> this test red; restored, green. Second mutation: the clause hashed
    # `inspect(raw_body)` rather than the body, which is still one id per
    # body -> this test red too, on the ledger's message ids, which is what
    # pins the digest to the body rather than to any function of it;
    # restored, green.
    test "two identical bodies are one delivery and one duplicate" do
      config = config(self())

      assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _no_match]} =
               Webhook.handle(config, request(), now: @now)

      assert {:ok, [{:duplicate, "impressions_to_join"}, _no_match]} =
               Webhook.handle(config, request(), now: @now)

      # A different body under the same key is a different message, so it
      # is stepped into the execution the first one created. That execution
      # already left the state that takes an impression, so the step
      # selects nothing: dropped: unmatched_event (ADR-0004, the Note of
      # 2026-09-25).
      other_body = ~s({"kind":"impression","impression_id":"imp_7f3a","placement":"footer"})

      other =
        request(%{raw_body: other_body, data: Map.put(@data, "placement", "footer")})

      assert {:ok, [{:dropped, "impressions_to_join", :unmatched_event}, _no_match]} =
               Webhook.handle(config, other, now: @now)

      assert executions() == 1

      assert [_created, _duplicate, %{execution_id: ^execution_id}] = ledger(config)

      assert Enum.map(ledger(config), &{&1.outcome, &1.message_id}) == [
               {"created_and_delivered", @body_sha},
               {"duplicate", @body_sha},
               {"dropped: unmatched_event",
                Base.encode16(:crypto.hash(:sha256, other_body), case: :lower)}
             ]
    end

    # sabotage: source_event/1's fallback clause returned {:ok, request}
    # rather than the error, so the malformed requests reached route/3 and
    # came back with its reason rather than {:invalid_request, _} -> this
    # test red; restored, green.
    test "refuses a request it cannot build an event from, and routes nothing" do
      config = recording_config()

      for bad <- [
            Map.delete(request(), :raw_body),
            Map.delete(request(), :scope),
            request(%{source: :ad_events}),
            request(%{data: []})
          ] do
        assert {:error, {:invalid_request, ^bad}} = Webhook.handle(config, bad, now: @now)
      end

      refute_received {:deliver, _binding_id, _key, _delivery}
      assert ledger(config) == []
    end

    # sabotage: message_id/1's non-binary-body clause deleted, so a request
    # carrying `raw_body: nil` or an integer body fell through to the
    # provider id -> the first two rows routed, red; restored, green. Second
    # mutation: message_id/1's provider-id-alone clause guarded on is_binary
    # alone -> the "" row routed, red; restored, green.
    test "refuses a non-binary raw body, and no body without a provider id" do
      config = recording_config()
      without_body = Map.delete(request(), :raw_body)

      for bad <- [
            request(%{raw_body: nil, provider_id: "evt_5b1d"}),
            request(%{raw_body: 4071, provider_id: "evt_5b1d"}),
            Map.put(without_body, :provider_id, ""),
            Map.put(without_body, :provider_id, 4071),
            Map.put(without_body, :provider_id, nil),
            Map.delete(without_body, :provider_id)
          ] do
        assert {:error, {:invalid_request, ^bad}} = Webhook.handle(config, bad, now: @now)
      end

      refute_received {:deliver, _binding_id, _key, _delivery}
      assert ledger(config) == []
    end

    # sabotage: source_event/1's first clause was made to require a
    # :selector key -> the second call, which sends none, was refused, red;
    # restored, green.
    test "does not read the request's selector" do
      config = recording_config()

      assert {:ok, [{:delivered, "impressions_to_join", _}, _no_match]} =
               Webhook.handle(config, request(%{selector: %{"path" => "/anything-at-all"}}),
                 now: @now
               )

      assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: @body_sha}}

      assert {:ok, [{:delivered, "impressions_to_join", _}, _no_match]} =
               Webhook.handle(config, Map.delete(request(), :selector), now: @now)

      assert_received {:deliver, "impressions_to_join", "imp_7f3a", %{message_id: @body_sha}}
    end

    # sabotage: handle/3 dropped `opts` and called route/3 with [] -> the
    # ledger row carried DateTime.utc_now/0 rather than @now, red;
    # restored, green.
    test "passes its options through to route/3" do
      config = recording_config()

      assert {:error, {:unknown_key, :nope}} = Webhook.handle(config, request(), nope: 1)

      config = config(self())
      assert {:ok, _outcomes} = Webhook.handle(config, request(), now: @now)
      assert [row] = ledger(config)
      assert row.inserted_at == @now
    end
  end

  describe "status/1" do
    # sabotage: status/1's {:ok, _} clause answered 500 -> every recorded
    # outcome red; restored, green. Second mutation: the {:error, _} clause
    # answered 200 -> the error case red; restored, green.
    test "is 200 for every recorded answer and 500 for an error" do
      recorded = [
        [],
        [{:delivered, "clicks_to_join", "ex_9k2q"}],
        [{:created_and_delivered, "impressions_to_join", "ex_9k2q"}],
        [{:duplicate, "clicks_to_join"}],
        [{:dropped, "clicks_to_join", :no_execution}],
        [{:dropped, "clicks_to_join", :finished}],
        [{:no_match, "clicks_to_join"}],
        [{:key_refused, "clicks_to_join", {:key, {:value, :undefined}}}]
      ]

      for outcomes <- recorded do
        assert Webhook.status({:ok, outcomes}) == 200
      end

      for reason <- [:no_message_id, {:invalid_event, %{}}, {:invalid_request, %{}}, :timeout] do
        assert Webhook.status({:error, reason}) == 500
      end
    end
  end
end
