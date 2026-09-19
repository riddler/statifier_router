defmodule StatifierRouter.Migrations do
  @moduledoc """
  Versioned migrations for this package's tables, in the shape
  statifier_persistence's `StatifierPersistence.Ecto.Migrations` uses: the
  host writes one ordinary migration that delegates here, and later
  package versions ship higher-numbered migration modules the same call
  picks up.

      defmodule MyApp.Repo.Migrations.AddStatifierRouter do
        use Ecto.Migration

        def up, do: StatifierRouter.Migrations.up(prefix: "routing")
        def down, do: StatifierRouter.Migrations.down(prefix: "routing")
      end

  The options are the two storage options of `StatifierRouter.Config`,
  `:table_prefix` and `:prefix`, resolved the same way, plus `:from` and
  `:version`:

    * `:table_prefix` - a string prefixed to every table name, default
      `"statifier_router_"`. Pass the same value the host's
      `StatifierRouter.Config` carries.
    * `:prefix` - the Postgres schema the tables live in, default `nil`.
      When it is set, `up/1` creates the schema if it does not exist and
      `down/1` leaves it in place: dropping a schema the host may share is
      not this package's call.
    * `:from` and `:version` - where a call starts and where it ends, in
      both directions. `up/1` migrates from `from:` (default: V01) up
      through `version:` (default: the newest this package knows), and
      `down/1` rolls back from `from:` (default: the newest) down through
      `version:` (default: V01, that is, everything).

  A host already running an older version writes its next migration with
  `from:` set to the first version it has not run, rather than re-running
  V01's `CREATE TABLE` against tables that already exist. A host whose
  first migration is capped with `version: N` caps its rollback to match
  with `from: N`.

  A fault in the options raises `ArgumentError`: a migration has no caller
  to hand an `{:error, reason}` to.

  `StatifierRouter.Migrations.V01` records what the first version creates.
  """

  alias StatifierRouter.Config

  @initial_version 1

  @migrations %{
    1 => StatifierRouter.Migrations.V01
  }

  # Read off the map rather than written beside it, so the default target
  # cannot name a version this module does not reach.
  @current_version @migrations |> Map.keys() |> Enum.max()

  @doc """
  Migrates the tables from `from:` (default: V01) up through `version:`
  (default: the newest).
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) when is_list(opts) do
    {from, opts} = Keyword.pop(opts, :from, @initial_version)
    validate_version!(from, "from")
    {storage, target} = parse!(opts, @current_version)

    from
    |> span!(target, :up)
    |> Enum.each(fn version -> Map.fetch!(@migrations, version).up(storage) end)
  end

  @doc """
  Rolls the tables back from `from:` (default: the newest version this
  package knows) down through `version:` (default: V01, that is,
  everything).
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) when is_list(opts) do
    {from, opts} = Keyword.pop(opts, :from, @current_version)
    validate_version!(from, "from")
    {storage, target} = parse!(opts, @initial_version)

    from
    |> span!(target, :down)
    |> Enum.each(fn version -> Map.fetch!(@migrations, version).down(storage) end)
  end

  # The versions a call walks, in the order it walks them. A span that runs
  # the wrong way for its direction is a fault in the host's options.
  defp span!(from, target, :up) when from <= target, do: from..target//1
  defp span!(from, target, :down) when from >= target, do: from..target//-1

  defp span!(from, target, :up) do
    raise ArgumentError, "from: #{from} is above version: #{target}; up/1 does not roll back"
  end

  defp span!(from, target, :down) do
    raise ArgumentError, "from: #{from} is below version: #{target}; down/1 does not migrate up"
  end

  defp parse!(opts, default_version) do
    {version, opts} = Keyword.pop(opts, :version, default_version)
    validate_version!(version, "version")

    with :ok <- Config.reject_unknown(opts, Config.storage_keys()),
         {:ok, storage} <- Config.storage(opts) do
      {Map.new(storage), version}
    else
      {:error, reason} ->
        raise ArgumentError, "invalid migration options: #{inspect(reason)}"
    end
  end

  defp validate_version!(version, name) do
    if not (is_integer(version) and version in @initial_version..@current_version) do
      raise ArgumentError,
            "unknown migration #{name} #{inspect(version)}; " <>
              "this package knows versions #{@initial_version} through #{@current_version}"
    end

    :ok
  end
end
