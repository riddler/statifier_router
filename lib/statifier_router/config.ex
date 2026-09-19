defmodule StatifierRouter.Config do
  @moduledoc """
  The router's resolved configuration: the host's repo, where this
  package's tables live in it, the bindings events are routed by, and the
  module each delivery is handed to.

  `new/1` takes a keyword list and returns `{:ok, config}` or
  `{:error, reason}`:

  | Option | Value | Default |
  |---|---|---|
  | `:repo` | the host's `Ecto.Repo` module | required |
  | `:delivery` | the module `StatifierRouter.route/3` hands each delivery to | required |
  | `:bindings` | a list of bindings, each a map or keyword list `StatifierRouter.Binding.new/1` accepts, or a `%StatifierRouter.Binding{}` it built | `[]` |
  | `:table_prefix` | a string prefixed to every table name | `"statifier_router_"` |
  | `:prefix` | the Postgres schema the tables live in, as a string | `nil` (the repo's default) |

  `:delivery` is required because this release ships no delivery module of
  its own; `StatifierRouter` documents what the module must answer.

  Each binding is built with `StatifierRouter.Binding.new/1`, in the order
  given, and the resolved configuration keeps that order: it is the order
  `StatifierRouter.route/3` returns its outcomes in. A duplicate binding
  `id` is a fault of the list rather than of any one binding, so it is
  refused here, naming the duplicated `id`, before any event is routed
  (ADR-0001, section 1).

  The three tables are the address table of ADR-0002 (`addresses`), the
  dedupe table of ADR-0003 (`dedupe`) and the ledger of ADR-0004
  (`routing_ledger`); `table/2` names each one under a configuration.
  `StatifierRouter.Migrations` creates them from the same two storage
  options, and `put_meta/2` and `queryable/2` point the schemas in
  `StatifierRouter.Schema` at them, so the DDL and the rows cannot
  disagree on a name.

      iex> {:ok, config} =
      ...>   StatifierRouter.Config.new(
      ...>     repo: MyApp.Repo,
      ...>     delivery: MyApp.Delivery,
      ...>     prefix: "routing"
      ...>   )
      iex> StatifierRouter.Config.table(config, :addresses)
      "statifier_router_addresses"
      iex> config.prefix
      "routing"
  """

  alias StatifierRouter.Binding
  alias StatifierRouter.Schema

  @enforce_keys [:repo, :delivery]
  defstruct [:repo, :delivery, :prefix, bindings: [], table_prefix: "statifier_router_"]

  @type t :: %__MODULE__{
          repo: module(),
          delivery: module(),
          bindings: [Binding.t()],
          table_prefix: String.t(),
          prefix: String.t() | nil
        }

  @typedoc "One of the three tables this package owns."
  @type table :: :addresses | :dedupe | :routing_ledger

  @typedoc "Why `new/1` refused a configuration."
  @type new_error ::
          {:unknown_key, term()}
          | {:missing_key, :repo | :delivery}
          | {:invalid_value, atom(), term()}
          | {:invalid_config, term()}
          | {:binding, non_neg_integer(), Binding.new_error()}
          | {:duplicate_binding_id, String.t()}

  @tables [:addresses, :dedupe, :routing_ledger]
  @storage_keys [:table_prefix, :prefix]
  @known [:repo, :delivery, :bindings | @storage_keys]

  @schemas %{
    Schema.Address => :addresses,
    Schema.Dedupe => :dedupe,
    Schema.Ledger => :routing_ledger
  }

  @doc """
  Validates the options in the table above and resolves them into a
  configuration.

  Returns `{:ok, config}`, or `{:error, reason}` naming the first fault:
  an unknown option, then a missing or malformed `:repo`, then a missing or
  malformed `:delivery`, then a storage value the table does not allow,
  then the first binding `StatifierRouter.Binding.new/1` refuses, as
  `{:binding, index, reason}` with `index` counted from zero, then the
  first duplicated binding `id`.

      iex> StatifierRouter.Config.new(repo: MyApp.Repo, delivery: MyApp.Delivery, table_prefix: 7)
      {:error, {:invalid_value, :table_prefix, 7}}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, new_error()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_config, opts}},
         :ok <- reject_unknown(opts, @known),
         {:ok, repo} <- fetch_module(opts, :repo),
         {:ok, delivery} <- fetch_module(opts, :delivery),
         {:ok, storage} <- storage(opts),
         {:ok, bindings} <- bindings(opts) do
      {:ok,
       struct!(__MODULE__, [{:repo, repo}, {:delivery, delivery}, {:bindings, bindings} | storage])}
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

  defp fetch_module(opts, name) do
    case Keyword.fetch(opts, name) do
      {:ok, module} when is_atom(module) and not is_nil(module) and not is_boolean(module) ->
        {:ok, module}

      {:ok, other} ->
        {:error, {:invalid_value, name, other}}

      :error ->
        {:error, {:missing_key, name}}
    end
  end

  defp bindings(opts) do
    case Keyword.get(opts, :bindings, []) do
      list when is_list(list) ->
        with {:ok, bindings} <- build_bindings(list),
             :ok <- refuse_duplicate_ids(bindings) do
          {:ok, bindings}
        end

      other ->
        {:error, {:invalid_value, :bindings, other}}
    end
  end

  defp build_bindings(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case build_binding(attrs) do
        {:ok, binding} -> {:cont, {:ok, [binding | acc]}}
        {:error, reason} -> {:halt, {:error, {:binding, index, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp build_binding(%Binding{} = binding), do: {:ok, binding}
  defp build_binding(attrs), do: Binding.new(attrs)

  defp refuse_duplicate_ids(bindings) do
    bindings
    |> Enum.reduce_while(MapSet.new(), fn %Binding{id: id}, seen ->
      if MapSet.member?(seen, id),
        do: {:halt, {:duplicate, id}},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      {:duplicate, id} -> {:error, {:duplicate_binding_id, id}}
      _seen -> :ok
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
