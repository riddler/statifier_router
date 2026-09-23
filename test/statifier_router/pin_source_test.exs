defmodule StatifierRouter.PinSourceTest do
  use ExUnit.Case, async: true, group: :database

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.PinSource
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.TestRepo

  # The module a host writes: `use StatifierRouter.PinSource` with the
  # configuration read from the process dictionary, so each test's own
  # configuration reaches the callback that has no argument for it.
  defmodule RouterPins do
    use StatifierRouter.PinSource, config: Process.get(:pin_source_config)
  end

  @hash "sha256:impression_click_join"

  setup do
    :ok = Sandbox.checkout(TestRepo)
    {:ok, config} = Config.new(repo: TestRepo, delivery: StatifierRouter.RecordingDelivery)
    Process.put(:pin_source_config, config)
    %{config: config}
  end

  defp address(config, key, execution_id, document \\ "impression_click_join") do
    TestRepo.insert!(
      Config.put_meta(config, %Address{
        scope: "7c1e",
        document: document,
        key: key,
        execution_id: execution_id
      })
    )
  end

  describe "pins/2" do
    # sabotage: the count query dropped its `where a.execution_id in ^ids`
    # -> the count came back 3 for two active executions, red; restored,
    # green.
    test "counts the address rows naming the context's executions and no others",
         %{config: config} do
      address(config, "imp_7f3a", "ex_live_one")
      address(config, "imp_91ab", "ex_live_two")
      address(config, "imp_c40d", "ex_other_chart")

      assert RouterPins.pins(@hash, %{execution_ids: ["ex_live_one", "ex_live_two"]}) ==
               %{addresses: 2}

      assert RouterPins.pins(@hash, %{execution_ids: ["ex_other_chart"]}) == %{addresses: 1}
    end

    test "answers zero for a hash with no active executions", %{config: config} do
      address(config, "imp_7f3a", "ex_live_one")

      assert RouterPins.pins(@hash, %{execution_ids: []}) == %{addresses: 0}
    end

    # sabotage: `count/2` read the context with `Map.get(context,
    # :execution_ids, [])` instead of matching it -> the malformed context
    # answered zero and collect/3 answered {:ok, ...}, red; restored,
    # green.
    test "raises for a context carrying no execution ids, which collect/3 reports as a failure" do
      assert {:error, {RouterPins, {:raised, %FunctionClauseError{}}}} =
               PinSource.collect([RouterPins], @hash, %{})
    end

    test "collects under the module's own name", %{config: config} do
      address(config, "imp_7f3a", "ex_live_one")

      assert PinSource.collect([RouterPins], @hash, %{execution_ids: ["ex_live_one"]}) ==
               {:ok, %{RouterPins => %{addresses: 1}}}
    end
  end

  describe "under a table prefix and a Postgres schema" do
    # sabotage: addresses/2 counted from the bare `Address` schema instead
    # of `Config.queryable(config, Address)` -> the count read the default
    # table and came back 1, red; restored, green.
    test "counts the rows in the configured table and not the default one",
         %{config: config} do
      SQL.query!(TestRepo, ~s(CREATE SCHEMA "pins_elsewhere"))

      SQL.query!(
        TestRepo,
        ~s(CREATE TABLE "pins_elsewhere"."kx_addresses" ) <>
          "(LIKE statifier_router_addresses INCLUDING ALL)"
      )

      elsewhere = %{config | table_prefix: "kx_", prefix: "pins_elsewhere"}
      address(elsewhere, "copy_4417", "ex_loan_one", "loan")
      address(elsewhere, "copy_5520", "ex_loan_two", "loan")
      address(config, "copy_6031", "ex_loan_one", "loan")

      context = %{execution_ids: ["ex_loan_one", "ex_loan_two"]}

      Process.put(:pin_source_config, elsewhere)
      assert RouterPins.pins("sha256:loan", context) == %{addresses: 2}
      assert StatifierRouter.PinSource.count(elsewhere, context) == %{addresses: 2}

      assert StatifierRouter.PinSource.count(config, context) == %{addresses: 1}
    end
  end

  describe "the module `use` writes" do
    # sabotage: __using__/1 dropped `@behaviour StatifierPersistence.PinSource`
    # (and the `@impl` naming it) -> the attribute list carried no
    # behaviour, red; restored, green.
    test "declares the behaviour statifier_persistence defines" do
      behaviours =
        RouterPins.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PinSource in behaviours
    end
  end

  describe "a configuration that is not a %StatifierRouter.Config{}" do
    # sabotage: count/2's first clause matched any `config` instead of
    # `%Config{}` -> the keyword list reached `config.repo` and raised
    # KeyError instead of FunctionClauseError, red; restored, green.
    test "raises in count/2, which collect/3 reports as a failure" do
      Process.put(:pin_source_config, repo: TestRepo)

      assert {:error, {RouterPins, {:raised, %FunctionClauseError{}}}} =
               PinSource.collect([RouterPins], "sha256:loan", %{execution_ids: ["ex_loan_one"]})
    end
  end

  describe "StatifierRouter.PinSource itself" do
    # sabotage: StatifierRouter.PinSource gained a `pins/2` answering
    # %{addresses: 0} -> collect/3 answered {:ok, ...}, red; restored,
    # green.
    test "is not a pin source: naming it is a source failure, never a count" do
      assert {:error, {StatifierRouter.PinSource, {:raised, %UndefinedFunctionError{}}}} =
               PinSource.collect([StatifierRouter.PinSource], "sha256:loan", %{
                 execution_ids: ["ex_loan_one"]
               })
    end
  end
end
