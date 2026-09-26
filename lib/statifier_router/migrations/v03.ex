defmodule StatifierRouter.Migrations.V03 do
  @moduledoc """
  V03 of the package DDL: renames the subscription table's unique index to
  a name that fits in a Postgres identifier. It creates no table and no
  column.

  `StatifierRouter.Migrations.V02` names that index
  `<table>_execution_id_binding_id_invoke_id_index`, which under the
  default table prefix is
  `statifier_router_subscriptions_execution_id_binding_id_invoke_id_index`,
  70 bytes. Postgres keeps at most 63 bytes of an identifier and truncates
  a longer one when it creates it, so a database that ran V02 holds the
  index as `statifier_router_subscriptions_execution_id_binding_id_invoke_i`.
  V02 itself is left as it shipped: every database that already ran it
  keeps what it built, and this version renames what it finds.

  **Index**: the unique `<table>_invocation_index` on `(execution_id,
  binding_id, invoke_id)`, 47 bytes under the default table prefix. Only
  the name changes: the columns, their order and the uniqueness are V02's,
  and nothing is rebuilt.

  `up/1` renames the index from the name Postgres gave it under V02 - V02's
  spelling cut to 63 bytes, at a character boundary, the way Postgres cuts
  it - so it names the index exactly as the database holds it, whether or
  not V02's name was truncated under the host's table prefix, and
  Postgres has nothing to truncate. `down/1` renames it back to that same
  name.

  Each direction renames only an index it finds under the name it renames
  from (`ALTER INDEX IF EXISTS`), and otherwise does nothing. That is what
  lets a host's migration that runs V03 on its own sit behind an earlier
  one that already walked through V03 on a fresh database: the second run
  finds the index already renamed and leaves it.

  A host already running V02 reaches this version with
  `StatifierRouter.Migrations.up(from: 3)`: `from:` names the first
  version the host has **not** run and the walk includes it.
  """

  use Ecto.Migration

  alias StatifierRouter.Config

  # Postgres's NAMEDATALEN - 1: the most bytes an identifier keeps.
  @max_identifier_bytes 63

  @typedoc "The resolved storage options `StatifierRouter.Migrations` hands each version."
  @type storage :: %{
          required(:table_prefix) => String.t(),
          required(:prefix) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "Renames V02's subscription index to `<table>_invocation_index`."
  @spec up(storage()) :: :ok
  def up(storage) do
    {v02_name, v03_name} = names(storage)
    rename_index(storage, v02_name, v03_name)
  end

  @doc "Renames the subscription index back to the name V02 left it under."
  @spec down(storage()) :: :ok
  def down(storage) do
    {v02_name, v03_name} = names(storage)
    rename_index(storage, v03_name, v02_name)
  end

  # Both names as Postgres holds them: V02's as its CREATE INDEX left it,
  # this version's as the rename will leave it.
  defp names(%{table_prefix: table_prefix}) do
    subscriptions = Config.table_name(table_prefix, :subscriptions)

    {as_stored("#{subscriptions}_execution_id_binding_id_invoke_id_index"),
     as_stored("#{subscriptions}_invocation_index")}
  end

  defp rename_index(%{prefix: prefix}, from, to) do
    execute("ALTER INDEX IF EXISTS #{qualified(prefix, from)} RENAME TO #{quoted(to)}")

    :ok
  end

  defp qualified(nil, name), do: quoted(name)
  defp qualified(prefix, name), do: quoted(prefix) <> "." <> quoted(name)

  defp quoted(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # An identifier as Postgres stores it: at most 63 bytes, cut at the last
  # whole character that fits (Postgres's truncate_identifier/3). Postgres
  # would cut a longer name in the ALTER INDEX the same way, with a notice;
  # spelling it cut already is what keeps the rename quiet.
  defp as_stored(name) when byte_size(name) <= @max_identifier_bytes, do: name

  defp as_stored(name) do
    name
    |> String.codepoints()
    |> Enum.reduce_while("", fn char, kept ->
      if byte_size(kept) + byte_size(char) <= @max_identifier_bytes,
        do: {:cont, kept <> char},
        else: {:halt, kept}
    end)
  end
end
