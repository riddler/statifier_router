defmodule StatifierRouter.Adapter do
  @moduledoc false

  # Which Ecto adapter a repo module runs on, read in one place for every
  # statement or DDL in this package that differs by dialect. Internal to
  # the package: no host calls it, and nothing here is public API.
  #
  # The adapter is what the repo module's own `__adapter__/0` answers,
  # which every module built with `use Ecto.Repo` exports. A module that
  # exports none - one that delegates to an Ecto repo rather than being
  # one - names no adapter, and every question below answers false for
  # it, so it takes the form every adapter other than Postgres takes.
  #
  # SQLite is read one step further than Postgres. A repo whose adapter
  # module is not the stock one can still speak SQLite: a wrapper that
  # hands every callback to `Ecto.Adapters.SQLite3` starts the stock
  # SQLite connection, and that connection module writes every statement
  # and every piece of DDL the repo sends. So for an adapter module that
  # is neither stock module, `sqlite?/1` asks the running repo which
  # connection module writes its SQL. A Postgres repo's is the Postgres
  # connection module, wrapped or not, so the reading never takes a
  # Postgres repo for SQLite. An adapter with a connection module of its
  # own, even one that speaks SQLite, is not recognised.

  @doc false
  @spec adapter(module()) :: module() | nil
  def adapter(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0),
      do: repo.__adapter__()
  end

  # Postgres by the stock adapter module alone: a repo on any other
  # module, or on none, keeps the statements it sends today.
  @doc false
  @spec postgres?(module()) :: boolean()
  def postgres?(repo), do: adapter(repo) == Ecto.Adapters.Postgres

  # SQLite by the stock adapter module, or, for an adapter module that is
  # neither stock module, by the stock SQLite connection writing the
  # running repo's SQL. That second reading asks the repo's registry
  # entry, so it is for a started repo, as a migration's always is.
  @doc false
  @spec sqlite?(module()) :: boolean()
  def sqlite?(repo) do
    case adapter(repo) do
      nil -> false
      Ecto.Adapters.SQLite3 -> true
      Ecto.Adapters.Postgres -> false
      _other -> sql_connection(repo) == Ecto.Adapters.SQLite3.Connection
    end
  end

  # The module the running repo's adapter writes SQL with, or nil for an
  # adapter whose metadata names none.
  defp sql_connection(repo) do
    case Ecto.Adapter.lookup_meta(repo.get_dynamic_repo()) do
      %{sql: connection} -> connection
      _meta -> nil
    end
  end
end
