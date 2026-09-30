defmodule StatifierRouter.StatusStore do
  @moduledoc """
  A storage adapter that answers one read, `fetch_execution/2`, from a map
  of execution id to status handed to it when the store is built:

      %StatifierPersistence.Storage{adapter: __MODULE__, opts: %{"ex_1" => :completed}}

  An id the map does not name answers `{:error, :execution_not_found}`.
  It lets a test reap address rows in a repo that holds no execution
  table, the SQLite repo of `StatifierRouter.SQLiteReapTest`. Test-only
  support code, not part of the package's public API.
  """

  @doc "The execution's status as the map names it, or `:execution_not_found`."
  @spec fetch_execution(%{String.t() => atom()}, String.t()) ::
          {:ok, %{status: atom()}} | {:error, :execution_not_found}
  def fetch_execution(statuses, execution_id) do
    case Map.fetch(statuses, execution_id) do
      {:ok, status} -> {:ok, %{status: status}}
      :error -> {:error, :execution_not_found}
    end
  end
end
