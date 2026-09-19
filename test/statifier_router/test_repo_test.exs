defmodule StatifierRouter.TestRepoTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)
  end

  # Proves the harness reaches a real Postgres through the PG* env vars:
  # a temporary table lives only inside this test's sandbox transaction.
  # sabotage: dropping the insert_all/3 call turned this test red (the read
  # returned []); restored, green.
  test "inserts and reads one row through TestRepo" do
    SQL.query!(TestRepo, "CREATE TEMPORARY TABLE harness_probe (id integer, label text)")

    assert {1, nil} = TestRepo.insert_all("harness_probe", [%{id: 1, label: "impression"}])

    assert [%{id: 1, label: "impression"}] =
             TestRepo.all(from(p in "harness_probe", select: %{id: p.id, label: p.label}))
  end
end
