defmodule StatifierRouter.PostgresReapTest do
  # The statements StatifierRouter.Addresses.reap/3 sends on Postgres, read
  # from the repo's query telemetry event: each batch of ids is bound as
  # one array, so every batch of a write is the same statement whatever
  # its length. The SQLite half of the same branch is in
  # StatifierRouter.SQLiteReapTest. The execution statuses come from
  # StatifierRouter.StatusStore, so the reap reads no execution table.
  use ExUnit.Case, async: true, group: :database

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.Storage
  alias StatifierRouter.Addresses
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.TestRepo

  @now ~U[2026-10-02 12:00:00.000000Z]
  @hour 3_600_000
  @numbers 7001..8201

  setup do
    :ok = Sandbox.checkout(TestRepo)

    handler = "postgres-reap-#{System.unique_integer([:positive])}"
    query = TestRepo.config()[:telemetry_prefix] ++ [:query]
    :ok = :telemetry.attach(handler, query, &__MODULE__.handle_query/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok
  end

  @doc false
  # Runs in the process that sent the query, so a statement this test's
  # own process sent is the only one it is told about.
  def handle_query(_event, _measurements, %{query: query}, test) do
    if self() == test, do: send(test, {:query, query})
  end

  # Every UPDATE or DELETE statement this test sent, in order.
  defp writes do
    receive do
      {:query, "UPDATE " <> _ = query} -> [query | writes()]
      {:query, "DELETE " <> _ = query} -> [query | writes()]
      {:query, _other} -> writes()
    after
      0 -> []
    end
  end

  # The delivered-scan binding, whose horizon keeps a delivered parcel's
  # row for an hour after a reap first sees it delivered.
  defp bindings do
    {:ok, binding} =
      Binding.new(%{
        id: "delivered_scans",
        source: "depot_scans",
        match: "event.kind == 'delivered'",
        key: "event.parcel_id",
        document: "parcel_delivery",
        event: "delivered",
        data: ["parcel_id"],
        dedupe: %{by: :message_id, horizon_ms: @hour}
      })

    [binding]
  end

  # One address row per delivered parcel, more rows than one statement
  # binds, so a reap writes them in batches of two lengths.
  defp seed do
    for chunk <- Enum.chunk_every(@numbers, 100) do
      rows =
        for n <- chunk do
          %{
            scope: "depot_north",
            document: "parcel_delivery",
            key: "pcl_#{n}",
            execution_id: "ex_pcl_#{n}",
            inserted_at: @now
          }
        end

      TestRepo.insert_all(Address, rows)
    end

    {:ok, config} =
      Config.new(
        repo: TestRepo,
        delivery: StatifierRouter.RecordingDelivery,
        store: %Storage{
          adapter: StatifierRouter.StatusStore,
          opts: Map.new(@numbers, &{"ex_pcl_#{&1}", :completed})
        }
      )

    config
  end

  describe "reap/3 on Postgres" do
    # sabotage: made postgres?/1 answer false, so stamp/3 and delete/2 took
    # the spliced IN form on Postgres -> red, the three stamp batches sent
    # two statement texts (a 500-parameter IN list and a 201-parameter
    # one), not one; restored, green.
    test "binds each batch of ids as one array, so every batch of a write is one statement" do
      config = seed()

      assert Addresses.reap(config, bindings(), now: @now, limit: 2_000) ==
               {:ok, %{stamped: 1201, deleted: 0, next: nil}}

      stamps = writes()
      assert length(stamps) == 3
      assert [stamp] = Enum.uniq(stamps)
      assert stamp =~ "= ANY("
      refute stamp =~ " IN ("

      an_hour_on = DateTime.add(@now, @hour, :millisecond)

      assert Addresses.reap(config, bindings(), now: an_hour_on, limit: 2_000) ==
               {:ok, %{stamped: 0, deleted: 1201, next: nil}}

      deletes = writes()
      assert length(deletes) == 3
      assert [delete] = Enum.uniq(deletes)
      assert delete =~ "= ANY("
      refute delete =~ " IN ("

      assert TestRepo.aggregate(Config.queryable(config, Address), :count) == 0
    end
  end
end
