defmodule StatifierRouter.BindingsResolverTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Broadway.Message
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Contracts
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo

  # ADR-0001, the Amendment of 2026-09-25: the binding set as a function of
  # scope. Two depots route the same parcel_scans source: the north depot's
  # scans reach its parcel_route executions, the south depot's reach its
  # held_parcel_route executions under bindings of their own.

  defmodule NoDepots do
    @moduledoc false
    @behaviour StatifierRouter.BindingsResolver

    @impl StatifierRouter.BindingsResolver
    def resolve(_scope), do: []
  end

  @north "3b9d"
  @south "5a21"

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  defp built(maps), do: Enum.map(maps, &(&1 |> Binding.new() |> elem(1)))

  defp north_bindings, do: built(parcel_bindings("parcel_route"))

  defp south_bindings do
    "held_parcel_route"
    |> parcel_bindings()
    |> Enum.map(&%{&1 | id: "held_" <> &1.id})
    |> built()
  end

  # A resolver answering each depot's bindings, reporting every call to
  # the test process.
  defp depots(pid) do
    fn scope ->
      send(pid, {:bindings_for, scope})

      case scope do
        @north -> north_bindings()
        @south -> south_bindings()
        _other -> []
      end
    end
  end

  defp recording_config(resolver) do
    {:ok, config} =
      Config.new(repo: TestRepo, delivery: RecordingDelivery, bindings_resolver: resolver)

    config
  end

  defp scan(scope, message_id, kind),
    do: %{parcel_scan(message_id, kind) | scope: scope}

  defp message(event) do
    %Message{
      data: event.data,
      metadata: Map.take(event, [:scope, :message_id, :source]),
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  # The execution the impression-and-click join's first event creates,
  # under the scope 7c1e, which the resolver below answers the join's
  # bindings for.
  defp joined_execution(config) do
    assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
             StatifierRouter.route(config, impression(), now: ~U[2026-09-19 08:00:00.000000Z])

    execution_id
  end

  defp join_resolver(pid, answer_for_7c1e) do
    fn scope ->
      send(pid, {:bindings_for, scope})
      if scope == "7c1e", do: answer_for_7c1e.(), else: []
    end
  end

  describe "Config.new/1" do
    # sabotage: binding_source/1 accepted any resolver in place of asking
    # BindingsResolver.valid?/1 -> the arity-2 fun was accepted, red;
    # restored, green. Second mutation:
    # BindingsResolver.valid?/1's module clause dropped
    # function_exported?/3 -> Binding was accepted, red; restored, green.
    test "takes a module implementing the behaviour or an arity-1 fun, and nothing else" do
      fun = fn _scope -> [] end
      base = [repo: TestRepo, delivery: RecordingDelivery]

      assert {:ok, %Config{bindings_resolver: nil, bindings: []}} = Config.new(base)

      assert {:ok, %Config{bindings_resolver: nil}} =
               Config.new(base ++ [bindings_resolver: nil])

      assert {:ok, %Config{bindings_resolver: ^fun, bindings: []}} =
               Config.new(base ++ [bindings_resolver: fun])

      assert {:ok, %Config{bindings_resolver: NoDepots}} =
               Config.new(base ++ [bindings_resolver: NoDepots])

      for value <- [fn _scope, _source -> [] end, Binding, NotAModule, "depots", true] do
        assert Config.new(base ++ [bindings_resolver: value]) ==
                 {:error, {:invalid_value, :bindings_resolver, value}}
      end
    end

    # sabotage: binding_source/1's exclusive arm accepted the resolver in
    # place of refusing -> both keys were accepted, red; restored, green.
    test "refuses :bindings and :bindings_resolver both given, an empty list included" do
      base = [repo: TestRepo, delivery: RecordingDelivery, bindings_resolver: NoDepots]

      for bindings <- [[], parcel_bindings()] do
        assert Config.new(base ++ [bindings: bindings]) ==
                 {:error, {:exclusive_keys, :bindings, :bindings_resolver}}
      end
    end
  end

  describe "route/3 under a bindings resolver" do
    # sabotage: route/3 read config.bindings in place of
    # Config.bindings_for/2 -> no binding for either scope, {:ok, []}, red;
    # restored, green. Second mutation: bindings_for/2 called the resolver
    # with a fixed scope of @north -> the south scan was delivered under
    # the north depot's binding, red; restored, green.
    test "two scopes answer different bindings for the same source" do
      config = recording_config(depots(self()))

      assert StatifierRouter.route(config, scan(@north, "parcel_scans/1/1", "loaded")) ==
               {:ok, [{:delivered, "loaded_scans", "ex_9k2q"}, {:no_match, "delivered_scans"}]}

      assert_received {:bindings_for, @north}
      assert_received {:deliver, "loaded_scans", "pcl_4821", %{name: "loaded"}}

      assert StatifierRouter.route(config, scan(@south, "parcel_scans/1/2", "loaded")) ==
               {:ok,
                [
                  {:delivered, "held_loaded_scans", "ex_9k2q"},
                  {:no_match, "held_delivered_scans"}
                ]}

      assert_received {:bindings_for, @south}
      assert_received {:deliver, "held_loaded_scans", "pcl_4821", %{name: "loaded"}}

      # A scope the resolver answers no bindings for routes nowhere.
      assert StatifierRouter.route(config, scan("7c1e", "parcel_scans/1/3", "loaded")) ==
               {:ok, []}

      # Once per call, and never for the calls above twice.
      assert_received {:bindings_for, "7c1e"}
      refute_received {:bindings_for, _scope}
    end

    # sabotage: bindings_for/2 skipped refuse_reserved_id/1 -> the answer
    # under the reserved id was routed, red; restored, green. Second
    # mutation: bindings_for/2 skipped refuse_duplicate_ids/1 -> the
    # answer with the duplicated id was routed, red; restored, green.
    test "refuses an answer carrying the reserved or a duplicated id before any binding" do
      [loaded, delivered] = north_bindings()
      reserved = SendHandler.execution_target()

      reserved_config = recording_config(fn _scope -> [loaded, %{delivered | id: reserved}] end)

      assert StatifierRouter.route(reserved_config, scan(@north, "parcel_scans/2/1", "loaded")) ==
               {:error, {:reserved_binding_id, reserved}}

      duplicate_config = recording_config(fn _scope -> [loaded, %{delivered | id: loaded.id}] end)

      assert StatifierRouter.route(duplicate_config, scan(@north, "parcel_scans/2/2", "loaded")) ==
               {:error, {:duplicate_binding_id, "loaded_scans"}}

      refute_received {:deliver, _binding_id, _key, _delivery}
      assert TestRepo.all(Config.queryable(reserved_config, Ledger)) == []
    end

    # sabotage: BindingsResolver.call/2 returned the answer unchecked -> a
    # FunctionClauseError from the duplicate-id check in place of
    # ArgumentError, red; restored, green.
    test "raises on an answer that is not a list of built bindings" do
      unbuilt = recording_config(fn _scope -> parcel_bindings() end)

      assert_raise ArgumentError, ~r/expected a list of %StatifierRouter.Binding\{\}/, fn ->
        StatifierRouter.route(unbuilt, scan(@north, "parcel_scans/3/1", "loaded"))
      end

      not_a_list = recording_config(fn _scope -> :none end)

      assert_raise ArgumentError, fn ->
        StatifierRouter.route(not_a_list, scan(@north, "parcel_scans/3/2", "loaded"))
      end
    end
  end

  describe "the partitioner under a bindings resolver" do
    # sabotage: partition/3 read router.bindings in place of
    # Config.bindings_for/2 -> both scans hashed by their message ids, red;
    # restored, green. Second mutation: the refused arm hashed the scope
    # in place of the message id -> red; restored, green.
    test "hashes each scope's own address, and the message id for a refused answer" do
      config = recording_config(depots(self()))
      normalize = &StatifierRouter.Broadway.normalize/1

      assert StatifierRouter.Broadway.partition(
               message(scan(@north, "parcel_scans/4/1", "loaded")),
               config,
               normalize
             ) == :erlang.phash2({@north, "parcel_route", "pcl_4821"})

      assert StatifierRouter.Broadway.partition(
               message(scan(@south, "parcel_scans/4/2", "loaded")),
               config,
               normalize
             ) == :erlang.phash2({@south, "held_parcel_route", "pcl_4821"})

      [loaded, _delivered] = north_bindings()
      refused = recording_config(fn _scope -> [loaded, loaded] end)

      assert StatifierRouter.Broadway.partition(
               message(scan(@north, "parcel_scans/4/3", "loaded")),
               refused,
               normalize
             ) == :erlang.phash2("parcel_scans/4/3")
    end
  end

  describe "subscribe/3 under a bindings resolver" do
    # sabotage: binding_and_address/3's resolver clause checked the binding
    # in config.bindings -> {:unknown_binding, _}, red; restored, green.
    # Second mutation: it asked the resolver for the scope "" in place of
    # the address row's -> {:unknown_binding, _}, red; restored, green.
    test "finds the binding in the resolver's answer for the address row's scope" do
      config =
        config(self(), bindings_resolver: join_resolver(self(), fn -> built(bindings()) end))

      execution_id = joined_execution(config)

      assert StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"}) ==
               {:ok, :subscribed}

      assert_received {:bindings_for, "7c1e"}

      assert StatifierRouter.subscribe(config, "loaded_scans", {execution_id, "inv_2"}) ==
               {:error, {:unknown_binding, "loaded_scans"}}
    end

    # sabotage: resolved_bindings!/2 answered [] for a refused answer ->
    # {:unknown_binding, _} in place of the raise, red; restored, green.
    test "raises on an answer the reserved-id check refuses" do
      reserved = SendHandler.execution_target()

      # The first answer routes the impression; every later one carries the
      # reserved id.
      answers = :counters.new(1, [])

      answer = fn ->
        :counters.add(answers, 1, 1)
        [first | rest] = built(bindings())

        if :counters.get(answers, 1) == 1,
          do: [first | rest],
          else: [%{first | id: reserved} | rest]
      end

      config = config(self(), bindings_resolver: join_resolver(self(), answer))
      execution_id = joined_execution(config)

      assert_raise ArgumentError, ~r/reserved_binding_id/, fn ->
        StatifierRouter.subscribe(config, "clicks_to_join", {execution_id, "inv_1"})
      end
    end
  end

  describe "the publish-time checks under a bindings resolver" do
    # sabotage: check/3 read the resolver's answer for the scope 7c1e in
    # place of config.bindings -> the resolver was called and the join's
    # bindings were reported, red; restored, green. Second mutation:
    # bindings_unchecked/1's resolver clause answered [] -> no
    # :bindings_resolver entry, red; restored, green.
    test "read the configuration's empty list, say so, and never call the resolver" do
      unpublished = fn _document -> {:error, :not_published} end
      machine = Map.fetch!(machines(), "parcel_route")

      static = config(self())
      static_report = Contracts.check(static, machine, unpublished)

      assert [_impressions, _clicks] = static_report.undeclared_binding_events
      refute Enum.any?(static_report.unchecked, &match?(%{reason: :bindings_resolver}, &1))

      resolved =
        config(self(), bindings_resolver: join_resolver(self(), fn -> built(bindings()) end))

      assert %{
               undeclared_binding_events: [],
               unchecked: [%{reason: :bindings_resolver, location: nil} | _located]
             } = Contracts.check(resolved, machine, unpublished)

      refute_received {:bindings_for, _scope}
    end
  end
end
