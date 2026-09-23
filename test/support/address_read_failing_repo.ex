defmodule StatifierRouter.AddressReadFailingRepo do
  @moduledoc """
  `StatifierRouter.TestRepo` with one deliberate interference: every
  `one/1` read fails in Postgres. The read is answered by a statement the
  server refuses, so it fails the way any failed SELECT does - leaving the
  transaction it ran in aborted until something rolls it back - and the
  error is raised to the caller. Every other call passes through to
  `StatifierRouter.TestRepo` untouched.

  It exists for the unregistered route's refusal in
  `StatifierRouter.SendHandler`, whose only `one/1` is the sender's
  address-row read ahead of the ledger row: a configuration carrying this
  module as its `:repo` makes that read fail on purpose, so a test can see
  whether the sending step survives it. Only the callbacks that refusal
  reaches are defined. Test-only support code, not part of the package's
  public API.
  """

  alias StatifierRouter.TestRepo

  @doc """
  Fails in Postgres instead of reading: the statement divides by zero, the
  server refuses it and the error is raised.
  """
  @spec one(Ecto.Queryable.t()) :: no_return()
  def one(_queryable), do: TestRepo.query!("SELECT 1 / 0")

  @doc "Delegates to `StatifierRouter.TestRepo.insert!/1`."
  @spec insert!(struct()) :: struct()
  defdelegate insert!(row), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.query!/1`."
  @spec query!(String.t()) :: term()
  defdelegate query!(sql), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.transaction/1`."
  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: var
  defdelegate transaction(fun), to: TestRepo
end
