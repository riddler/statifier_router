defmodule StatifierRouter.LedgerFailingRepo do
  @moduledoc """
  `StatifierRouter.TestRepo` with one deliberate interference: inserting a
  `send_refused` ledger row fails in Postgres. The row is sent with its
  `scope` emptied, so the server refuses it for the column's `NOT NULL`
  and the statement fails the way any failed insert does - leaving the
  transaction it ran in aborted until something rolls it back. Every other
  row, and every other call, passes through to `StatifierRouter.TestRepo`
  untouched.

  It exists for the refusal paths of `StatifierRouter.SendHandler`, which
  write their row inside the sending execution's own transaction: a
  configuration carrying this module as its `:repo` makes that write fail
  on purpose, so a test can see whether the sending step survives it.
  Only the callbacks a delivery and a refusal reach are defined. Test-only
  support code, not part of the package's public API.
  """

  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.TestRepo

  @doc """
  `StatifierRouter.TestRepo.insert!/1`, except that a `send_refused` ledger
  row is inserted with no `scope`, which the server refuses.
  """
  @spec insert!(struct()) :: struct()
  def insert!(%Ledger{outcome: "send_refused"} = row), do: TestRepo.insert!(%{row | scope: nil})
  def insert!(row), do: TestRepo.insert!(row)

  @doc "Delegates to `StatifierRouter.TestRepo.insert!/2`."
  @spec insert!(struct(), keyword()) :: struct()
  defdelegate insert!(row, opts), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.insert_all/3`."
  @spec insert_all(term(), [map()], keyword()) :: {non_neg_integer(), nil | [term()]}
  defdelegate insert_all(source, entries, opts), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.one/1`."
  @spec one(Ecto.Queryable.t()) :: struct() | nil
  defdelegate one(queryable), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.one!/1`."
  @spec one!(Ecto.Queryable.t()) :: struct()
  defdelegate one!(queryable), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.update_all/2`."
  @spec update_all(Ecto.Queryable.t(), keyword()) :: {non_neg_integer(), nil | [term()]}
  defdelegate update_all(queryable, updates), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.query!/1`."
  @spec query!(String.t()) :: term()
  defdelegate query!(sql), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.transaction/1`."
  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: var
  defdelegate transaction(fun), to: TestRepo
end
