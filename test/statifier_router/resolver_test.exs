defmodule StatifierRouter.ResolverTest do
  use ExUnit.Case, async: true

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Machine
  alias StatifierRouter.Config
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.TestRepo

  doctest StatifierRouter.Resolver.Static

  @now ~U[2026-09-19 08:00:00.000000Z]

  # A module-form resolver: the join chart under every scope, nothing else.
  defmodule JoinOnly do
    @behaviour StatifierRouter.Resolver

    @impl StatifierRouter.Resolver
    def resolve(_scope, "impression_click_join") do
      machine = Map.fetch!(StatifierRouter.DeliveryFixtures.machines(), "impression_click_join")
      {Machine.identity(machine).content_hash, machine}
    end

    def resolve(_scope, _document), do: {:error, :not_published}
  end

  describe "StatifierRouter.Resolver.Static" do
    # sabotage: new/1's resolver looked charts up by document alone ->
    # the 91ab scope resolved to the 7c1e machine, red; restored, green.
    test "answers the machine's own identity hash for a pair it holds, :not_found otherwise" do
      join = Map.fetch!(machines(), "impression_click_join")
      {:ok, resolver} = Static.new(%{{"7c1e", "impression_click_join"} => join})

      assert resolver.("7c1e", "impression_click_join") ==
               {Machine.identity(join).content_hash, join}

      assert resolver.("91ab", "impression_click_join") == {:error, :not_found}
      assert resolver.("7c1e", "instant_join") == {:error, :not_found}
    end

    # sabotage: entry/1 accepted a machine whose identity is nil ->
    # new/1 answered {:ok, _}, red; restored, green. Second mutation:
    # entry/1's fallback clause returned {:ok, ...} -> a malformed key
    # was accepted, red; restored, green.
    test "refuses a map it cannot answer from" do
      join = Map.fetch!(machines(), "impression_click_join")
      unidentified = %{join | identity: nil}

      assert Static.new(%{{"7c1e", "impression_click_join"} => unidentified}) ==
               {:error, {:unidentified_chart, {"7c1e", "impression_click_join"}}}

      assert Static.new(%{"impression_click_join" => join}) ==
               {:error, {:invalid_entry, {"impression_click_join", join}}}

      assert Static.new(%{{"7c1e", "impression_click_join"} => :join}) ==
               {:error, {:invalid_entry, {{"7c1e", "impression_click_join"}, :join}}}

      assert Static.new([]) == {:error, {:invalid_charts, []}}
    end
  end

  describe "a module-form resolver" do
    setup do
      :ok = Sandbox.checkout(TestRepo)
      :ok
    end

    # sabotage: Resolver.valid?/1 accepted only funs -> Config.new/1
    # refused JoinOnly, red; restored, green. Second mutation: valid?/1
    # skipped the resolve/2 export check -> Config accepted
    # StatifierRouter.Config as a resolver, red; restored, green.
    test "Config.new/1 accepts a module exporting resolve/2 and refuses one that does not" do
      config = config(self(), resolver: JoinOnly)
      assert config.resolver == JoinOnly

      for value <- [StatifierRouter.Config, NotAModule.Anywhere, nil, true, "JoinOnly"] do
        opts = [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery, resolver: value]
        assert Config.new(opts) == {:error, {:invalid_value, :resolver, value}}
      end
    end

    # sabotage: Resolver.call/3's module clause called resolve/2 with
    # (document, scope) -> JoinOnly answered :not_published and route/3
    # returned an error, red; restored, green.
    test "is called on the create path, and its error is route/3's error" do
      config = config(self(), resolver: JoinOnly)

      assert {:ok, [{:created_and_delivered, "impressions_to_join", _}, _]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert executions() == 1

      unpublished = %{config | bindings: [%{hd(config.bindings) | document: "unpublished"}]}

      other_message = event("ad_events/3/2001", impression().data)

      assert StatifierRouter.route(unpublished, other_message, now: @now) ==
               {:error, {:unresolved_document, "unpublished", :not_published}}

      assert executions() == 1
    end
  end
end
