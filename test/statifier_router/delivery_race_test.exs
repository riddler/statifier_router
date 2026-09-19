defmodule StatifierRouter.DeliveryRaceTest do
  @moduledoc """
  Two first events for one key, delivered at once from two processes
  (ADR-0003, section 3).

  Live, outside the SQL sandbox, for the reason statifier_persistence's
  own caller-transaction tests give: the sandbox funnels every process
  through one owned connection, so the second delivery's transaction
  could not start until the first had ended, its lookup would find the
  first's row, and the insert that settles the race would never run.
  Here each delivery is a real `BEGIN` / `COMMIT` on its own pooled
  connection, and the test holds the first open until the second is
  waiting on the unique index.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-19 08:00:00.000000Z]
  @scope "race-7c1e"

  setup do
    Sandbox.mode(TestRepo, :auto)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_scope()

    on_exit(fn ->
      delete_scope()
      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  # sabotage: insert_or_existing/4 inserted the address row without
  # on_conflict: :nothing -> the click's insert raised a unique_violation
  # once the impression committed, and the click's task exited, red;
  # restored, green.
  test "two concurrent first events: one address row, one execution, two inputs" do
    test_pid = self()
    config = config(test_pid, resolver: holding_resolver(test_pid))

    # The impression inserts its address row and then waits, inside its
    # open transaction, in the resolver.
    impression =
      Task.async(fn -> StatifierRouter.route(config, scoped(impression()), now: @now) end)

    assert_receive {:resolving, winner}, 5_000

    # The click finds no committed row, and its insert waits on the
    # impression's uncommitted one.
    click = Task.async(fn -> StatifierRouter.route(config, scoped(click()), now: @now) end)
    wait_for_lock_wait()

    send(winner, :resolve)

    assert {:ok, [{:created_and_delivered, "impressions_to_join", execution_id}, _]} =
             Task.await(impression, 5_000)

    assert {:ok, [_, {:delivered, "clicks_to_join", ^execution_id}]} = Task.await(click, 5_000)

    # The loser never asked for a chart: it never created.
    refute_received {:resolving, _}

    assert [%Address{execution_id: ^execution_id}] =
             TestRepo.all(from(a in Config.queryable(config, Address), where: a.scope == @scope))

    assert executions([execution_id]) == 1
    assert inputs(config, execution_id) == [{0, "step", "impression"}, {1, "step", "click"}]

    assert ["created_and_delivered", "delivered"] =
             TestRepo.all(
               from(l in Config.queryable(config, Ledger),
                 where: l.scope == @scope,
                 order_by: l.id,
                 select: l.outcome
               )
             )
  end

  # A resolver that tells the test which process is resolving, then waits
  # for the word to answer.
  defp holding_resolver(test_pid) do
    [machine] = Map.take(machines(), ["impression_click_join"]) |> Map.values()
    content_hash = Statifier.Machine.identity(machine).content_hash

    fn _scope, "impression_click_join" ->
      send(test_pid, {:resolving, self()})

      receive do
        :resolve -> {content_hash, machine}
      after
        5_000 -> {:error, :test_timed_out}
      end
    end
  end

  # Bounded: until a backend of this database waits on a lock, or 5s.
  defp wait_for_lock_wait(attempts \\ 500)

  defp wait_for_lock_wait(0), do: flunk("the second delivery never waited on a lock")

  defp wait_for_lock_wait(attempts) do
    %{rows: [[waiting]]} =
      SQL.query!(
        TestRepo,
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    if waiting > 0 do
      :ok
    else
      Process.sleep(10)
      wait_for_lock_wait(attempts - 1)
    end
  end

  defp scoped(event), do: %{event | scope: @scope}

  defp executions(execution_ids) do
    TestRepo.aggregate(
      from(e in TestPersistence.Execution, where: e.execution_id in ^execution_ids),
      :count
    )
  end

  defp delete_scope do
    {:ok, config} =
      Config.new(repo: TestRepo, delivery: StatifierRouter.RecordingDelivery)

    ids =
      TestRepo.all(
        from(a in Config.queryable(config, Address),
          where: a.scope == @scope,
          select: a.execution_id
        )
      )

    TestRepo.delete_all(from(i in TestPersistence.Input, where: i.execution_id in ^ids))
    TestRepo.delete_all(from(e in TestPersistence.Execution, where: e.execution_id in ^ids))
    TestRepo.delete_all(from(a in Config.queryable(config, Address), where: a.scope == @scope))
    TestRepo.delete_all(from(l in Config.queryable(config, Ledger), where: l.scope == @scope))
  end
end
