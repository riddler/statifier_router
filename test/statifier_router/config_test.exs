defmodule StatifierRouter.ConfigTest do
  use ExUnit.Case, async: true, group: :database

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Invoke.Types
  alias Statifier.Send.Routes
  alias StatifierPersistence.Storage
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger, Subscription}
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  doctest Config

  @delivery RecordingDelivery

  defmodule TripIds do
    @moduledoc false
    def execution_id(_scope, _document, key), do: "trip_" <> key
  end

  @impressions %{
    id: "impressions_to_join",
    source: "ad_events",
    match: "event.kind == 'impression'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "impression"
  }

  @clicks %{
    id: "clicks_to_join",
    source: "ad_events",
    match: "event.kind == 'click'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "click"
  }

  describe "new/1" do
    # sabotage: storage/1's table_prefix default changed to "statifier_"
    # -> red; restored, green.
    test "resolves the defaults" do
      assert {:ok,
              %Config{
                repo: TestRepo,
                delivery: @delivery,
                bindings: [],
                table_prefix: "statifier_router_",
                prefix: nil
              }} = Config.new(repo: TestRepo, delivery: @delivery)
    end

    # sabotage: fetch_module/2 returned {:ok, nil} when :repo was absent
    # -> red; restored, green.
    test "refuses a missing or malformed repo" do
      assert Config.new([]) == {:error, {:missing_key, :repo}}
      assert Config.new(repo: "TestRepo") == {:error, {:invalid_value, :repo, "TestRepo"}}
      assert Config.new(repo: nil) == {:error, {:invalid_value, :repo, nil}}
    end

    # sabotage: new/1 skipped reject_unknown/2 -> the unknown key was
    # accepted, red; restored, green.
    test "refuses an unknown key before anything else" do
      assert Config.new(bindingz: [], table_prefix: 7) == {:error, {:unknown_key, :bindingz}}
    end

    # sabotage: storage/1 accepted any prefix -> red on the integer
    # prefix; restored, green.
    test "refuses a malformed table prefix or Postgres schema" do
      base = [repo: TestRepo, delivery: @delivery]

      assert Config.new(base ++ [table_prefix: ""]) ==
               {:error, {:invalid_value, :table_prefix, ""}}

      assert Config.new(base ++ [prefix: 1]) == {:error, {:invalid_value, :prefix, 1}}
      assert Config.new(base ++ [prefix: ""]) == {:error, {:invalid_value, :prefix, ""}}
    end

    # sabotage: fetch_delivery/1 accepted any value it was given -> the
    # string delivery was accepted, red; restored, green.
    test "refuses a malformed delivery module" do
      assert Config.new(repo: TestRepo, delivery: "Delivery") ==
               {:error, {:invalid_value, :delivery, "Delivery"}}

      assert Config.new(repo: TestRepo, delivery: false) ==
               {:error, {:invalid_value, :delivery, false}}
    end

    # sabotage: delivery_needs/2 computed required? as false for every
    # delivery module -> the default delivery was accepted with no store,
    # red; restored, green.
    test "defaults to StatifierRouter.Delivery, which requires its four options" do
      {:ok, store} = Storage.new(Storage.InMemory, [])

      needs = [
        store: store,
        executor: fn _effect, _context -> :ok end,
        resolver: fn _scope, _document -> {:error, :none} end,
        chart_resolver: fn _content_hash -> :error end
      ]

      assert {:ok, %Config{delivery: StatifierRouter.Delivery, store: ^store}} =
               Config.new([repo: TestRepo] ++ needs)

      for {name, _value} <- needs do
        assert Config.new([repo: TestRepo] ++ Keyword.delete(needs, name)) ==
                 {:error, {:missing_key, name}}
      end
    end

    # sabotage: delivery_value?/2's :resolver clause accepted a fun of any
    # arity -> the arity-1 resolver was accepted, red; restored, green.
    test "checks each of the four options when given, whatever the delivery module" do
      for {name, value} <- [
            store: %{adapter: Storage.InMemory},
            executor: fn _effect -> :ok end,
            executor: nil,
            resolver: fn _document -> :error end,
            chart_resolver: fn _scope, _hash -> :error end
          ] do
        assert Config.new([repo: TestRepo, delivery: @delivery] ++ [{name, value}]) ==
                 {:error, {:invalid_value, name, value}}
      end

      assert {:ok, %Config{executor: RecordingDelivery, store: nil}} =
               Config.new(repo: TestRepo, delivery: @delivery, executor: RecordingDelivery)
    end

    # sabotage: hook?/3's fun clause accepted a fun of any arity -> the
    # arity-3 :on_create was accepted, red; restored, green. Second
    # mutation: hook?/3's module clause dropped function_exported?/3 -> a
    # module without create/4 was accepted, red; restored, green.
    test "takes :on_create and :on_step as a module exporting the call or a fun of its arity" do
      create = fn _store, _id, _machine, _opts -> {:error, :none} end
      step = fn _store, _id, _machine, _event, _opts -> {:error, :none} end
      base = [repo: TestRepo, delivery: @delivery]

      assert {:ok, %Config{on_create: nil, on_step: nil}} = Config.new(base)

      assert {:ok, %Config{on_create: ^create, on_step: ^step}} =
               Config.new(base ++ [on_create: create, on_step: step])

      assert {:ok,
              %Config{
                on_create: StatifierPersistence.Executions,
                on_step: StatifierPersistence.Executions
              }} =
               Config.new(
                 base ++
                   [
                     on_create: StatifierPersistence.Executions,
                     on_step: StatifierPersistence.Executions
                   ]
               )

      for {name, value} <- [
            on_create: fn _store, _id, _machine -> :ok end,
            on_create: step,
            on_create: StatifierRouter.Binding,
            on_create: "create",
            on_create: true,
            on_step: create,
            on_step: StatifierRouter.Binding,
            on_step: NotAModule
          ] do
        assert Config.new(base ++ [{name, value}]) == {:error, {:invalid_value, name, value}}
      end
    end

    # sabotage: @minter named execution_id/2 -> the arity-3 fun was
    # refused and the arity-2 one accepted, red; restored, green.
    test "takes :execution_id as a module exporting execution_id/3 or an arity-3 fun" do
      mint = fn _scope, _document, _key -> "trip_1" end
      base = [repo: TestRepo, delivery: @delivery]

      assert {:ok, %Config{execution_id: nil}} = Config.new(base)
      assert {:ok, %Config{execution_id: ^mint}} = Config.new(base ++ [execution_id: mint])

      assert {:ok, %Config{execution_id: TripIds}} =
               Config.new(base ++ [execution_id: TripIds])

      for value <- [
            fn _scope, _document -> "trip_1" end,
            fn _scope, _document, _key, _extra -> "trip_1" end,
            StatifierRouter.Binding,
            NotAModule,
            "trip_",
            true
          ] do
        assert Config.new(base ++ [execution_id: value]) ==
                 {:error, {:invalid_value, :execution_id, value}}
      end
    end

    # sabotage: same_repo/2's mismatch arm returned :ok -> the store over
    # another repo was accepted, red; restored, green.
    test "refuses a store whose adapter options name another repo" do
      {:ok, own} = Storage.new(Storage.Ecto, persistence: TestPersistence)
      other = %Storage{adapter: Storage.Ecto, opts: [repo: OtherRepo]}

      assert {:ok, %Config{store: ^own}} =
               Config.new([repo: TestRepo] ++ Keyword.put(needs(), :store, own))

      assert Config.new([repo: TestRepo] ++ Keyword.put(needs(), :store, other)) ==
               {:error, {:invalid_value, :store, other}}

      # An adapter that resolves no :repo is passed through unchecked: the
      # in-memory storage is one, and the moduledoc says so.
      {:ok, memory} = Storage.new(Storage.InMemory, [])

      assert {:ok, %Config{store: ^memory}} =
               Config.new([repo: TestRepo] ++ Keyword.put(needs(), :store, memory))
    end

    # sabotage: persistence_options/1 accepted any keyword list -> the
    # :initialize key was accepted, red; restored, green.
    test "carries the statifier_persistence snapshot options, and only those" do
      snapshot = [
        routes: Routes.new(),
        invoke_types: Types.new(types: ["myapp:authorize"])
      ]

      assert {:ok, %Config{persistence_options: ^snapshot}} =
               Config.new(repo: TestRepo, delivery: @delivery, persistence_options: snapshot)

      assert {:ok, %Config{persistence_options: []}} =
               Config.new(repo: TestRepo, delivery: @delivery)

      for refused <- [[initialize: []], [executor: @delivery], [:routes], %{}] do
        assert Config.new(
                 repo: TestRepo,
                 delivery: @delivery,
                 persistence_options: refused
               ) == {:error, {:invalid_value, :persistence_options, refused}}
      end
    end

    # sabotage: build_bindings/1 prepended without the final reverse ->
    # the order came back reversed, red; restored, green.
    test "builds every binding through Binding.new/1 and keeps their order" do
      {:ok, built} = Binding.new(@clicks)

      assert {:ok, %Config{bindings: [%Binding{id: "impressions_to_join"}, ^built]}} =
               Config.new(repo: TestRepo, delivery: @delivery, bindings: [@impressions, built])
    end

    # sabotage: build_binding/1 passed a %Binding{} through Binding.new/1
    # again -> the altered struct was refused, red; restored, green.
    # Second mutation: new/1 skipped refuse_reserved_id/1 -> the struct
    # under the reserved id was accepted, red; restored, green.
    test "keeps a prebuilt binding as given; the list-wide checks still apply" do
      {:ok, built} = Binding.new(@clicks)
      altered = %{built | source: 7}

      assert {:ok, %Config{bindings: [^altered]}} =
               Config.new(repo: TestRepo, delivery: @delivery, bindings: [altered])

      reserved = StatifierRouter.SendHandler.execution_target()

      assert Config.new(repo: TestRepo, delivery: @delivery, bindings: [%{built | id: reserved}]) ==
               {:error, {:reserved_binding_id, reserved}}
    end

    # sabotage: build_bindings/1 skipped a binding Binding.new/1 refused ->
    # the configuration was accepted, red; restored, green.
    test "refuses the first binding Binding.new/1 refuses, naming its index" do
      assert Config.new(
               repo: TestRepo,
               delivery: @delivery,
               bindings: [@impressions, Map.put(@clicks, :mode, :batch)]
             ) == {:error, {:binding, 1, {:reserved_key, :mode}}}

      assert Config.new(repo: TestRepo, delivery: @delivery, bindings: :none) ==
               {:error, {:invalid_value, :bindings, :none}}
    end

    # sabotage: new/1 skipped refuse_duplicate_ids/1 -> the duplicated id
    # was accepted, red; restored, green.
    test "refuses a duplicate binding id, naming it" do
      again = %{@clicks | match: "event.kind == 'tap'"}

      assert Config.new(
               repo: TestRepo,
               delivery: @delivery,
               bindings: [@clicks, @impressions, again]
             ) == {:error, {:duplicate_binding_id, "clicks_to_join"}}
    end

    # sabotage: new/1's non-list clause removed -> FunctionClauseError,
    # red; restored, green.
    test "refuses something that is not a keyword list" do
      assert Config.new(%{repo: TestRepo}) == {:error, {:invalid_config, %{repo: TestRepo}}}
      assert Config.new([:repo]) == {:error, {:invalid_config, [:repo]}}
    end
  end

  defp needs do
    [
      store: elem(Storage.new(Storage.InMemory, []), 1),
      executor: fn _effect, _context -> :ok end,
      resolver: fn _scope, _document -> {:error, :none} end,
      chart_resolver: fn _content_hash -> :error end
    ]
  end

  describe "table/2" do
    # sabotage: table_name/2 dropped the table prefix -> red; restored,
    # green.
    test "names each table under the table prefix" do
      {:ok, config} = Config.new(repo: TestRepo, delivery: @delivery, table_prefix: "ads_")

      assert Enum.map(
               [:addresses, :dedupe, :routing_ledger, :subscriptions],
               &Config.table(config, &1)
             ) ==
               ["ads_addresses", "ads_dedupe", "ads_routing_ledger", "ads_subscriptions"]
    end
  end

  describe "the schemas under the default configuration" do
    setup do
      :ok = Sandbox.checkout(TestRepo)
      {:ok, config} = Config.new(repo: TestRepo, delivery: @delivery)
      {:ok, config: config}
    end

    # sabotage: Address's compiled source changed to "addresses" -> the
    # read through the schema raised (undefined table), red; restored, green.
    test "write and read the bootstrap's tables", %{config: config} do
      for row <- [
            %Address{
              scope: "7c1e",
              document: "impression_click_join",
              key: "imp_7f3a",
              execution_id: "ex_9k2q"
            },
            %Dedupe{
              binding_id: "impressions_to_join",
              message_id: "ad_events/3/1042",
              expires_at: DateTime.utc_now()
            },
            %Ledger{
              binding_id: "impressions_to_join",
              message_id: "ad_events/3/1042",
              scope: "7c1e",
              outcome: "created_and_delivered",
              key: "imp_7f3a",
              execution_id: "ex_9k2q"
            },
            %Subscription{
              binding_id: "clicks_to_join",
              execution_id: "ex_9k2q",
              invoke_id: "inv_1",
              scope: "7c1e",
              key: "imp_7f3a"
            }
          ] do
        %schema{id: id} = TestRepo.insert!(Config.put_meta(config, row))
        assert %{id: ^id} = TestRepo.get!(schema, id)
        assert %{id: ^id} = TestRepo.get!(Config.queryable(config, schema), id)
      end
    end

    # sabotage: table_for!/1 mapped any module to :addresses -> no
    # ArgumentError (UndefinedFunctionError instead), red; restored, green.
    test "refuse a module that is not one of the package's schemas", %{config: config} do
      assert_raise ArgumentError, ~r/not one of this package's schemas/, fn ->
        Config.queryable(config, Config)
      end
    end
  end
end
