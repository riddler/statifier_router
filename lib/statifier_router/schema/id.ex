defmodule StatifierRouter.Schema.Id do
  @moduledoc """
  The primary key type of the four schemas in `StatifierRouter.Schema`:
  the `id` of a row, whatever type the host's migration gave it.

  `StatifierRouter.Migrations.up/1` builds `id` as the host repo's
  implicit primary key - a `bigserial` unless the repo's
  `:migration_primary_key` says otherwise - or, under its `:primary_key`
  option, as the type and default the host names, a text id for
  instance. The database fills the column in either way, and a schema
  reads it back as the database holds it: an integer from an integer
  column, a string from a text column. The package never makes up an id
  itself and never compares one to anything but another id of the same
  table.

  Casting keeps what Ecto's own `:id` type does for an integer and for a
  string that spells one: `"42"` casts to `42`. Any other string casts to
  itself, so a host can look a row of a text-keyed table up by its id.
  An id made of digits alone is therefore read as an integer when it is
  cast, and a host whose text ids can be all digits reads such a row
  back through a query of its own rather than through a cast. The
  package's own reads never cast an id: they bind the values the table
  handed back.
  """

  use Ecto.Type

  @typedoc "A row's id: an integer from an integer column, a string from a text one."
  @type t :: integer() | String.t()

  # `:id` as the base type is what makes Ecto leave the column to the
  # database on insert and read it back with RETURNING, as it does for
  # the default primary key, whatever the column's type.
  @impl Ecto.Type
  def type, do: :id

  @impl Ecto.Type
  def cast(id) when is_integer(id), do: {:ok, id}

  def cast(id) when is_binary(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, integer} -> {:ok, integer}
      _not_an_integer -> {:ok, id}
    end
  end

  def cast(_other), do: :error

  @impl Ecto.Type
  def load(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  def load(_other), do: :error

  @impl Ecto.Type
  def dump(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  def dump(_other), do: :error
end
