defmodule StatifierRouter.SavepointFailingRepo do
  @moduledoc """
  `StatifierRouter.TestRepo` with one deliberate interference: the
  `RELEASE SAVEPOINT` and `ROLLBACK TO SAVEPOINT` statements that bracket
  the route-refusal ledger write both raise, the way they do when the
  connection has gone away under them. The `SAVEPOINT` that opens the
  bracket still runs, so the savepoint is really there and the insert
  really lands; every statement naming any other savepoint, and every
  other call, passes through to `StatifierRouter.TestRepo` untouched.

  It exists for the third exit of `StatifierRouter.SendHandler`'s
  refusal bracket: a release that raises after the insert has already
  succeeded. A configuration carrying this module as its `:repo` puts the
  handler on that exit on purpose. Test-only support code, not part of
  the package's public API.
  """

  alias StatifierRouter.TestRepo

  # The bracket's own savepoint prefix; nothing else in the package uses it.
  @refusal_savepoint "sr_route_refusal_"

  @doc """
  `StatifierRouter.TestRepo.query!/1`, except that a `RELEASE` or a
  `ROLLBACK TO` naming the refusal bracket's savepoint raises instead of
  running.
  """
  @spec query!(String.t()) :: term()
  def query!(sql) do
    if String.contains?(sql, @refusal_savepoint) and not String.starts_with?(sql, "SAVEPOINT ") do
      raise DBConnection.ConnectionError, "the connection is gone"
    end

    TestRepo.query!(sql)
  end

  @doc "Delegates to `StatifierRouter.TestRepo.one/1`."
  @spec one(Ecto.Queryable.t()) :: struct() | nil
  defdelegate one(queryable), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.all/1`."
  @spec all(Ecto.Queryable.t()) :: [struct()]
  defdelegate all(queryable), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.insert!/1`."
  @spec insert!(struct()) :: struct()
  defdelegate insert!(row), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.transaction/1`."
  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: var
  defdelegate transaction(fun), to: TestRepo
end
