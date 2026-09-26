defmodule StatifierRouter.MigratedDeliveryTest do
  # What a delivery does after statifier_persistence's migrate/4 moves an
  # addressed execution onto another chart, and while a refused migration
  # has parked it at :needs_migration. ADR-0002's Note of 2026-09-26 and
  # ADR-0004's Note of 2026-09-26 describe both paths; these tests prove
  # them with no router code of their own.
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures, only: [addresses: 1, config: 2, inputs: 2, ledger: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Machine
  alias StatifierPersistence.Execution
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.Storage
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Dedupe, Ledger}
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-26 10:00:00.000000Z]

  # A library loan as first published: a checkout puts the requested copy
  # on loan, and a return ends the loan.
  @loan_v1 """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="requested">
    <state id="requested">
      <transition event="checked_out" target="checked_out"/>
    </state>
    <state id="checked_out">
      <transition event="returned" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  # The library's edit: `checked_out` is renamed `on_loan`, and a loan on
  # it may now be renewed. The renewal logs on entry, so a step that takes
  # it hands the executor an effect only this chart can produce.
  @loan_v2 """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="requested">
    <state id="requested">
      <transition event="checked_out" target="on_loan"/>
    </state>
    <state id="on_loan">
      <transition event="renewed" target="renewed"/>
      <transition event="returned" target="returned"/>
    </state>
    <state id="renewed">
      <onentry><log label="loan_renewed"/></onentry>
      <transition event="returned" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  setup do
    :ok = Sandbox.checkout(TestRepo)

    {:ok, v1} = Statifier.compile(@loan_v1)
    {:ok, v2} = Statifier.compile(@loan_v2)
    v1_hash = Machine.identity(v1).content_hash
    v2_hash = Machine.identity(v2).content_hash
    refute v1_hash == v2_hash

    pid = self()
    sources = %{v1_hash => @loan_v1, v2_hash => @loan_v2}

    # A new loan starts on the chart as first published: the document
    # resolver answers the from chart throughout, so the chart an existing
    # loan steps on can only have come from its execution record.
    resolver = fn "7c1e", "library_loan" -> {v1_hash, v1} end

    # The host's chart resolver compiles the chart saved under the hash it
    # is asked for, and reports each hash to the test.
    chart_resolver = fn content_hash ->
      send(pid, {:chart_resolved, content_hash})

      with {:ok, source} <- Map.fetch(sources, content_hash),
           {:ok, machine} <- Statifier.compile(source) do
        {:ok, machine}
      else
        _other -> :error
      end
    end

    config =
      config(pid, resolver: resolver, chart_resolver: chart_resolver, bindings: loan_bindings())

    %{config: config, v1: v1, v2: v2, v1_hash: v1_hash, v2_hash: v2_hash}
  end

  describe "a migrated execution's next delivery" do
    # sabotage: existing/5 asked the document resolver for the machine
    # instead of the chart resolver -> the renewal handed step/5 the from
    # chart, step/5 refused it with {:identity_mismatch, _, _} and route/3
    # answered that error, red; restored, green.
    test "compiles the to hash through the chart resolver and steps on it; the address row is unchanged",
         %{config: config, v1: v1, v2: v2, v1_hash: v1_hash, v2_hash: v2_hash} do
      execution_id = check_out(config)
      addressed = addresses(config)

      {:ok, plan} = Plan.new(from: v1_hash, to: v2_hash, states: %{"checked_out" => "on_loan"})

      assert {:ok, %Execution{status: :active, content_hash: ^v2_hash}, _migrated} =
               Executions.migrate(config.store, execution_id, plan,
                 from_machine: v1,
                 to_machine: v2
               )

      # The migration wrote nothing of the router's.
      assert addresses(config) == addressed

      assert StatifierRouter.route(config, loan_event("loan_events/1/202", "renewed"), now: @now) ==
               {:ok,
                [
                  {:no_match, "checkouts"},
                  {:delivered, "renewals", execution_id},
                  {:no_match, "returns"}
                ]}

      assert_received {:chart_resolved, ^v2_hash}
      refute_received {:chart_resolved, ^v1_hash}
      assert_received {:effect, {:log, %{label: "loan_renewed"}}}

      assert {:ok, %{status: :active, content_hash: ^v2_hash}} =
               Storage.fetch_execution(config.store, execution_id)

      assert inputs(config, execution_id) == [{0, "step", "checked_out"}, {1, "step", "renewed"}]
      assert addresses(config) == addressed

      assert [
               %Ledger{outcome: "created_and_delivered"},
               %Ledger{
                 binding_id: "renewals",
                 message_id: "loan_events/1/202",
                 outcome: "delivered",
                 execution_id: ^execution_id
               }
             ] = ledger(config)
    end
  end

  describe "a delivery to a needs_migration execution" do
    # sabotage: guarded/5 released its savepoint on an error instead of
    # rolling back to it -> the refused return's dedupe row stayed and the
    # read-back found it, red; restored, green.
    test "rolls back with no ledger row and no dedupe row; the redelivery after unpark/3 lands",
         %{config: config, v1: v1, v2: v2, v1_hash: v1_hash, v2_hash: v2_hash} do
      execution_id = check_out(config)
      addressed = addresses(config)
      park(config, execution_id, v1, v2, v1_hash, v2_hash)

      returned = loan_event("loan_events/1/203", "returned")

      assert {:error, {:needs_migration, %Execution{execution_id: ^execution_id}}} =
               StatifierRouter.route(config, returned, now: @now)

      assert_refused(config, execution_id, addressed, "loan_events/1/203")

      assert {:ok, %Execution{status: :active, content_hash: ^v1_hash}} =
               Executions.unpark(config.store, execution_id)

      assert StatifierRouter.route(config, returned, now: @now) ==
               {:ok,
                [
                  {:no_match, "checkouts"},
                  {:no_match, "renewals"},
                  {:delivered, "returns", execution_id}
                ]}

      assert {:ok, %{status: :completed, content_hash: ^v1_hash}} =
               Storage.fetch_execution(config.store, execution_id)

      assert inputs(config, execution_id) == [{0, "step", "checked_out"}, {1, "step", "returned"}]
      assert addresses(config) == addressed
      assert dedupe_message_ids(config) == ["loan_events/1/201", "loan_events/1/203"]

      assert [
               %Ledger{outcome: "created_and_delivered"},
               %Ledger{
                 binding_id: "returns",
                 message_id: "loan_events/1/203",
                 outcome: "delivered",
                 execution_id: ^execution_id
               }
             ] = ledger(config)
    end

    # sabotage: existing/5 read :needs_migration as a terminal status ->
    # the renewal answered {:ok, outcomes} with a drop in place of the
    # needs_migration error, red; restored, green.
    test "rolls back with no ledger row and no dedupe row; the redelivery after a corrected migration lands",
         %{config: config, v1: v1, v2: v2, v1_hash: v1_hash, v2_hash: v2_hash} do
      execution_id = check_out(config)
      addressed = addresses(config)
      park(config, execution_id, v1, v2, v1_hash, v2_hash)

      renewed = loan_event("loan_events/1/204", "renewed")

      assert {:error, {:needs_migration, %Execution{execution_id: ^execution_id}}} =
               StatifierRouter.route(config, renewed, now: @now)

      assert_refused(config, execution_id, addressed, "loan_events/1/204")

      {:ok, corrected} =
        Plan.new(from: v1_hash, to: v2_hash, states: %{"checked_out" => "on_loan"})

      assert {:ok, %Execution{status: :active, content_hash: ^v2_hash}, _migrated} =
               Executions.migrate(config.store, execution_id, corrected,
                 from_machine: v1,
                 to_machine: v2
               )

      assert StatifierRouter.route(config, renewed, now: @now) ==
               {:ok,
                [
                  {:no_match, "checkouts"},
                  {:delivered, "renewals", execution_id},
                  {:no_match, "returns"}
                ]}

      assert_received {:chart_resolved, ^v2_hash}
      assert_received {:effect, {:log, %{label: "loan_renewed"}}}
      assert inputs(config, execution_id) == [{0, "step", "checked_out"}, {1, "step", "renewed"}]
      assert addresses(config) == addressed
      assert dedupe_message_ids(config) == ["loan_events/1/201", "loan_events/1/204"]

      assert [
               %Ledger{outcome: "created_and_delivered"},
               %Ledger{
                 binding_id: "renewals",
                 message_id: "loan_events/1/204",
                 outcome: "delivered",
                 execution_id: ^execution_id
               }
             ] = ledger(config)
    end
  end

  # The first delivery: a checkout creates the loan's execution on the from
  # chart and steps it to `checked_out`.
  defp check_out(config) do
    assert {:ok, [{:created_and_delivered, "checkouts", execution_id}, _, _]} =
             StatifierRouter.route(config, loan_event("loan_events/1/201", "checked_out"),
               now: @now
             )

    assert [_row] = addresses(config)
    execution_id
  end

  # A migration refused against the execution parks it: the plan leaves
  # `checked_out`, the state the loan is in, unmapped, and the to chart has
  # no state of that id.
  defp park(config, execution_id, v1, v2, v1_hash, v2_hash) do
    {:ok, plan} = Plan.new(from: v1_hash, to: v2_hash)

    assert {:parked, {:migration_refused, findings}} =
             Executions.migrate(config.store, execution_id, plan,
               from_machine: v1,
               to_machine: v2,
               on_failure: :park
             )

    assert {:unmapped_state, :configuration, "checked_out"} in findings

    assert {:ok, %{status: :needs_migration, content_hash: ^v1_hash}} =
             Storage.fetch_execution(config.store, execution_id)

    # The chart resolver has not been asked for any hash yet.
    refute_received {:chart_resolved, _}
  end

  # What the refused delivery left, read back: the checkout's rows and
  # nothing else.
  defp assert_refused(config, execution_id, addressed, message_id) do
    assert [%Ledger{outcome: "created_and_delivered", message_id: "loan_events/1/201"}] =
             ledger(config)

    assert dedupe_message_ids(config) == ["loan_events/1/201"]
    refute message_id in dedupe_message_ids(config)
    assert inputs(config, execution_id) == [{0, "step", "checked_out"}]
    assert addresses(config) == addressed

    assert {:ok, %{status: :needs_migration}} =
             Storage.fetch_execution(config.store, execution_id)
  end

  defp dedupe_message_ids(config) do
    config
    |> Config.queryable(Dedupe)
    |> TestRepo.all()
    |> Enum.map(& &1.message_id)
    |> Enum.sort()
  end

  # Three bindings on the `loan_events` source, keyed by the loan: a
  # checkout, a renewal and a return, all to the `library_loan` document.
  defp loan_bindings do
    for {id, kind} <- [
          {"checkouts", "checked_out"},
          {"renewals", "renewed"},
          {"returns", "returned"}
        ] do
      %{
        id: id,
        source: "loan_events",
        match: "event.kind == '#{kind}'",
        key: "event.loan_id",
        document: "library_loan",
        event: kind,
        data: ["loan_id", "copy_id"]
      }
    end
  end

  defp loan_event(message_id, kind) do
    %{
      scope: "7c1e",
      message_id: message_id,
      source: "loan_events",
      data: %{"kind" => kind, "loan_id" => "loan_5310", "copy_id" => "copy_4417"}
    }
  end
end
