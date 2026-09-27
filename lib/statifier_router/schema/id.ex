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

  Casting is exactly Ecto's own `:id` type: an integer casts to itself,
  a string that spells one casts to that integer (`"42"` to `42`), and
  any other string is refused, so a cast that worked or failed under
  the default key works or fails the same way. A text id is therefore
  never cast: a host on a text key looks a row up with a where clause
  that binds the id uncast, `where: fragment("? = ?", a.id, ^id)`,
  rather than with `Repo.get/2` or a changeset cast. The package's own
  reads bind ids that way too: they never cast an id.
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
  def cast(id), do: Ecto.Type.cast(:id, id)

  @impl Ecto.Type
  def load(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  def load(_other), do: :error

  @impl Ecto.Type
  def dump(id) when is_integer(id) or is_binary(id), do: {:ok, id}
  def dump(_other), do: :error
end
