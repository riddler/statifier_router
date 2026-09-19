defmodule StatifierRouter.ConfigTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Address, Dedupe, Ledger}
  alias StatifierRouter.TestRepo

  doctest Config

  describe "new/1" do
    # sabotage: storage/1's table_prefix default changed to "statifier_"
    # -> red; restored, green.
    test "resolves the defaults" do
      assert {:ok, %Config{repo: TestRepo, table_prefix: "statifier_router_", prefix: nil}} =
               Config.new(repo: TestRepo)
    end

    # sabotage: fetch_repo/1 returned {:ok, nil} when :repo was absent ->
    # red; restored, green.
    test "refuses a missing or malformed repo" do
      assert Config.new([]) == {:error, {:missing_key, :repo}}
      assert Config.new(repo: "TestRepo") == {:error, {:invalid_value, :repo, "TestRepo"}}
      assert Config.new(repo: nil) == {:error, {:invalid_value, :repo, nil}}
    end

    # sabotage: new/1 skipped reject_unknown/2 -> the unknown key was
    # accepted, red; restored, green.
    test "refuses an unknown key before anything else" do
      assert Config.new(bindings: [], table_prefix: 7) == {:error, {:unknown_key, :bindings}}
    end

    # sabotage: storage/1 accepted any prefix -> red on the integer
    # prefix; restored, green.
    test "refuses a malformed table prefix or Postgres schema" do
      assert Config.new(repo: TestRepo, table_prefix: "") ==
               {:error, {:invalid_value, :table_prefix, ""}}

      assert Config.new(repo: TestRepo, prefix: 1) == {:error, {:invalid_value, :prefix, 1}}
      assert Config.new(repo: TestRepo, prefix: "") == {:error, {:invalid_value, :prefix, ""}}
    end

    # sabotage: new/1's non-list clause removed -> FunctionClauseError,
    # red; restored, green.
    test "refuses something that is not a keyword list" do
      assert Config.new(%{repo: TestRepo}) == {:error, {:invalid_config, %{repo: TestRepo}}}
      assert Config.new([:repo]) == {:error, {:invalid_config, [:repo]}}
    end
  end

  describe "table/2" do
    # sabotage: table_name/2 dropped the table prefix -> red; restored,
    # green.
    test "names each table under the table prefix" do
      {:ok, config} = Config.new(repo: TestRepo, table_prefix: "ads_")

      assert Enum.map([:addresses, :dedupe, :routing_ledger], &Config.table(config, &1)) ==
               ["ads_addresses", "ads_dedupe", "ads_routing_ledger"]
    end
  end

  describe "the schemas under the default configuration" do
    setup do
      :ok = Sandbox.checkout(TestRepo)
      {:ok, config} = Config.new(repo: TestRepo)
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
