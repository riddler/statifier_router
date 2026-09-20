defmodule StatifierRouter.StampingRepo do
  @moduledoc """
  `StatifierRouter.TestRepo` with one deliberate interference: every
  address row `all/1` returns has already been stamped in the database,
  at `stamped_at/0`, by the time the caller sees it - and the structs it
  hands back still carry the empty `terminal_seen_at` the read found.

  That is the window `StatifierRouter.Addresses.reap/2`'s `is_nil` guard
  is for: a delivery stamping a row between the reap's read and the
  reap's write. A test whose configuration carries this module as its
  `:repo` puts the reaper in that window on purpose, and the guard is
  what keeps the reap from moving a stamp another writer already set.

  Only the three callbacks the reaper reaches are defined. Test-only
  support code, not part of the package's public API.
  """

  alias Ecto.Changeset
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.TestRepo

  @stamped_at ~U[2026-09-19 07:00:00.000000Z]

  @doc "The time this module stamps the rows it reads."
  @spec stamped_at() :: DateTime.t()
  def stamped_at, do: @stamped_at

  @doc """
  `StatifierRouter.TestRepo.all/1`, with every unstamped address row it
  returned stamped at `stamped_at/0` before the rows are handed back
  unchanged.
  """
  @spec all(Ecto.Queryable.t()) :: [struct()]
  def all(queryable) do
    rows = TestRepo.all(queryable)

    for %Address{terminal_seen_at: nil} = row <- rows do
      TestRepo.update!(Changeset.change(row, terminal_seen_at: @stamped_at))
    end

    rows
  end

  @doc "Delegates to `StatifierRouter.TestRepo.update_all/2`."
  @spec update_all(Ecto.Queryable.t(), keyword()) :: {non_neg_integer(), nil | [term()]}
  defdelegate update_all(queryable, updates), to: TestRepo

  @doc "Delegates to `StatifierRouter.TestRepo.delete_all/1`."
  @spec delete_all(Ecto.Queryable.t()) :: {non_neg_integer(), nil | [term()]}
  defdelegate delete_all(queryable), to: TestRepo
end
