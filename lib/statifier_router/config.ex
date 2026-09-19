defmodule StatifierRouter.Config do
  @moduledoc """
  The router's resolved configuration: the host's repo and where this
  package's tables live in it.

  `new/1` takes a keyword list and returns `{:ok, config}` or
  `{:error, reason}`:

  | Option | Value | Default |
  |---|---|---|
  | `:repo` | the host's `Ecto.Repo` module | required |
  | `:table_prefix` | a string prefixed to every table name | `"statifier_router_"` |
  | `:prefix` | the Postgres schema the tables live in, as a string | `nil` (the repo's default) |

  The three tables are the address table of ADR-0002 (`addresses`), the
  dedupe table of ADR-0003 (`dedupe`) and the ledger of ADR-0004
  (`routing_ledger`); `table/2` names each one under a configuration.
  `StatifierRouter.Migrations` creates them from the same two storage
  options, and `put_meta/2` and `queryable/2` point the schemas in
  `StatifierRouter.Schema` at them, so the DDL and the rows cannot
  disagree on a name.

      iex> {:ok, config} = StatifierRouter.Config.new(repo: MyApp.Repo, prefix: "routing")
      iex> StatifierRouter.Config.table(config, :addresses)
      "statifier_router_addresses"
      iex> config.prefix
      "routing"
  """

  alias StatifierRouter.Schema

  @enforce_keys [:repo]
  defstruct [:repo, :prefix, table_prefix: "statifier_router_"]

  @type t :: %__MODULE__{
          repo: module(),
          table_prefix: String.t(),
          prefix: String.t() | nil
        }

  @typedoc "One of the three tables this package owns."
  @type table :: :addresses | :dedupe | :routing_ledger

  @typedoc "Why `new/1` refused a configuration."
  @type new_error ::
          {:unknown_key, term()}
          | {:missing_key, :repo}
          | {:invalid_value, atom(), term()}
          | {:invalid_config, term()}

  @tables [:addresses, :dedupe, :routing_ledger]
  @storage_keys [:table_prefix, :prefix]
  @known [:repo | @storage_keys]

  @schemas %{
    Schema.Address => :addresses,
    Schema.Dedupe => :dedupe,
    Schema.Ledger => :routing_ledger
  }

  @doc """
  Validates the options in the table above and resolves them into a
  configuration.

  Returns `{:ok, config}`, or `{:error, reason}` naming the first fault:
  an unknown option, then a missing `:repo`, then a value the table does
  not allow.

      iex> StatifierRouter.Config.new(repo: MyApp.Repo, table_prefix: 7)
      {:error, {:invalid_value, :table_prefix, 7}}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, new_error()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_config, opts}},
         :ok <- reject_unknown(opts, @known),
         {:ok, repo} <- fetch_repo(opts),
         {:ok, storage} <- storage(opts) do
      {:ok, struct!(__MODULE__, [{:repo, repo} | storage])}
    end
  end

  def new(other), do: {:error, {:invalid_config, other}}

  @doc """
  The name of `table` under this configuration: the table prefix followed
  by the table's own name.
  """
  @spec table(t(), table()) :: String.t()
  def table(%__MODULE__{table_prefix: table_prefix}, table) when table in @tables,
    do: table_name(table_prefix, table)

  @doc """
  Points a row of one of the `StatifierRouter.Schema` modules at this
  configuration's table and Postgres schema, so that `Repo.insert/2`
  writes it there.
  """
  @spec put_meta(t(), struct()) :: struct()
  def put_meta(%__MODULE__{} = config, %schema{} = row) do
    Ecto.put_meta(row, source: table(config, table_for!(schema)), prefix: config.prefix)
  end

  @doc """
  A query over one of the `StatifierRouter.Schema` modules that reads this
  configuration's table in its Postgres schema.
  """
  @spec queryable(t(), module()) :: Ecto.Query.t()
  def queryable(%__MODULE__{} = config, schema) do
    {table(config, table_for!(schema)), schema}
    |> Ecto.Queryable.to_query()
    |> Ecto.Query.put_query_prefix(config.prefix)
  end

  # The storage half of new/1, shared with StatifierRouter.Migrations so the
  # migrations and the configuration resolve the same two options the same
  # way. Returns the resolved values as a keyword list.
  @doc false
  @spec storage(keyword()) :: {:ok, keyword()} | {:error, new_error()}
  def storage(opts) do
    table_prefix = Keyword.get(opts, :table_prefix, "statifier_router_")
    prefix = Keyword.get(opts, :prefix)

    cond do
      not (is_binary(table_prefix) and table_prefix != "") ->
        {:error, {:invalid_value, :table_prefix, table_prefix}}

      not (is_nil(prefix) or (is_binary(prefix) and prefix != "")) ->
        {:error, {:invalid_value, :prefix, prefix}}

      true ->
        {:ok, [table_prefix: table_prefix, prefix: prefix]}
    end
  end

  @doc false
  @spec storage_keys() :: [atom()]
  def storage_keys, do: @storage_keys

  @doc false
  @spec table_name(String.t(), table()) :: String.t()
  def table_name(table_prefix, table) when table in @tables,
    do: table_prefix <> Atom.to_string(table)

  @doc false
  @spec reject_unknown(keyword(), [atom()]) :: :ok | {:error, {:unknown_key, term()}}
  def reject_unknown(opts, known) do
    case Enum.find(opts, fn {name, _value} -> name not in known end) do
      nil -> :ok
      {name, _value} -> {:error, {:unknown_key, name}}
    end
  end

  defp fetch_repo(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_atom(repo) and not is_nil(repo) and not is_boolean(repo) ->
        {:ok, repo}

      {:ok, other} ->
        {:error, {:invalid_value, :repo, other}}

      :error ->
        {:error, {:missing_key, :repo}}
    end
  end

  defp table_for!(schema) do
    case Map.fetch(@schemas, schema) do
      {:ok, table} ->
        table

      :error ->
        raise ArgumentError,
              "#{inspect(schema)} is not one of this package's schemas; " <>
                "expected one of #{inspect(Map.keys(@schemas))}"
    end
  end
end
