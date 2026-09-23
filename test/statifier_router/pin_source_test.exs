defmodule StatifierRouter.PinSourceTest do
  use ExUnit.Case, async: true, group: :database

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

  defp address(config, key, execution_id) do
    TestRepo.insert!(
      Config.put_meta(config, %Address{
        scope: "7c1e",
        document: "impression_click_join",
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
end
