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
end
