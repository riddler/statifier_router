defmodule StatifierRouter.Config do
  @moduledoc """
  The router's resolved configuration: the host's repo, where this
  package's tables live in it, the bindings events are routed by, the
  module each delivery is handed to, and what that module needs to reach
  statifier_persistence.

  `new/1` takes a keyword list and returns `{:ok, config}` or
  `{:error, reason}`:

  | Option | Value | Default |
  |---|---|---|
  | `:repo` | the host's `Ecto.Repo` module | required |
  | `:delivery` | the module `StatifierRouter.route/3` hands each delivery to | `StatifierRouter.Delivery` |
  | `:store` | a `%StatifierPersistence.Storage{}` built over the same repo | required by `StatifierRouter.Delivery` |
  | `:persistence_options` | the per-call statifier_persistence snapshot options every create and every step carries: `:routes`, `:invoke_types`, `:send_types` | `[]` |
  | `:executor` | the `StatifierPersistence.Executor` effects are handed to: a module or an arity-2 fun | required by `StatifierRouter.Delivery` |
  | `:resolver` | the `StatifierRouter.Resolver` naming the chart a new execution starts on: a module implementing it or an arity-2 fun | required by `StatifierRouter.Delivery` |
  | `:chart_resolver` | a fun of `(content_hash)` compiling the chart an existing execution started on | required by `StatifierRouter.Delivery` |
  | `:bindings` | a list of bindings, each a map or keyword list `StatifierRouter.Binding.new/1` accepts, or a `%StatifierRouter.Binding{}` it built | `[]` |
  | `:table_prefix` | a string prefixed to every table name | `"statifier_router_"` |
  | `:prefix` | the Postgres schema the tables live in, as a string | `nil` (the repo's default) |

  `StatifierRouter` documents what a delivery module must answer, and
  `StatifierRouter.Delivery` what the four options it requires must be.
  A configuration that names another delivery module may leave those four
  out; one it gives is checked all the same. `:persistence_options` is
  never required: a configuration that omits it carries no snapshot, which
  is what statifier_persistence reads as "the built-in set only".

  ## What the checks here do and do not catch

  `:store` must be built over this configuration's own `:repo`, so that
  `StatifierPersistence.Executions.create/4` and
  `StatifierPersistence.Executions.step/5` write through the delivery's
  transaction rather than opening their own (ADR-0003, section 1). A store
  over another repo writes outside that transaction, and the delivery's
  rollback then leaves the execution behind. `new/1` catches the case it
  can see: a store whose resolved adapter options carry a `:repo` that is
  not this configuration's is refused with
  `{:error, {:invalid_value, :store, store}}`. Those options are
  statifier_persistence's own, and only its Ecto storage resolves a
  `:repo` into them, so a store built on any other adapter passes this
  check without being checked. On such a store the rule is the host's to
  keep, and keeping it is not optional.

  `:resolver` and `:executor` are checked to different depths, on purpose.
  `StatifierRouter.Resolver` is this package's own behaviour, so a resolver
  module is held to it: loadable and exporting `resolve/2`
  (`StatifierRouter.Resolver.valid?/1`). `StatifierPersistence.Executor` is
  the dependency's, normalized per effect by
  `StatifierPersistence.Executor.run/3`, so an executor is checked for the
  shape that option takes - a module name or an arity-2 fun - and the
  dependency's own dispatch rule is left to it. A host that wants the
  deeper check on its executor gets it from statifier_persistence, not from
  here.

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

  alias StatifierPersistence.Storage
  alias StatifierRouter.Binding
  alias StatifierRouter.Schema

  @enforce_keys [:repo, :delivery]
  defstruct [
    :repo,
    :delivery,
    :store,
    :executor,
    :resolver,
    :chart_resolver,
    :prefix,
    bindings: [],
    persistence_options: [],
    table_prefix: "statifier_router_"
  ]

  @typedoc """
  The host's answer to which chart a new execution of `document` starts on,
  under `scope` (ADR-0002, section 4): a module implementing
  `StatifierRouter.Resolver`, or an arity-2 fun with its callback's
  signature.
  """
  @type resolver :: StatifierRouter.Resolver.t()

  @typedoc """
  The host's compiled chart for a content hash an existing execution
  records, or `:error` when it has none: the shape
  `StatifierPersistence.Driver`'s `chart_resolver:` takes.
  """
  @type chart_resolver :: (content_hash :: String.t() -> {:ok, Statifier.Machine.t()} | :error)

  @type t :: %__MODULE__{
          repo: module(),
          delivery: module(),
          store: StatifierPersistence.Storage.t() | nil,
          executor: StatifierPersistence.Executor.t() | nil,
          resolver: resolver() | nil,
          chart_resolver: chart_resolver() | nil,
          bindings: [Binding.t()],
          persistence_options: keyword(),
          table_prefix: String.t(),
          prefix: String.t() | nil
        }

  @typedoc "One of the three tables this package owns."
  @type table :: :addresses | :dedupe | :routing_ledger

  @typedoc "Why `new/1` refused a configuration."
  @type new_error ::
          {:unknown_key, term()}
          | {:missing_key, :repo | :store | :executor | :resolver | :chart_resolver}
          | {:invalid_value, atom(), term()}
          | {:invalid_config, term()}
          | {:binding, non_neg_integer(), Binding.new_error()}
          | {:duplicate_binding_id, String.t()}

  @tables [:addresses, :dedupe, :routing_ledger]
  @storage_keys [:table_prefix, :prefix]
  @delivery_keys [:store, :executor, :resolver, :chart_resolver]
  @persistence_option_keys [:routes, :invoke_types, :send_types]
  @known [:repo, :delivery, :bindings, :persistence_options | @delivery_keys ++ @storage_keys]

  @schemas %{
    Schema.Address => :addresses,
    Schema.Dedupe => :dedupe,
    Schema.Ledger => :routing_ledger
  }

  @doc """
  Validates the options in the table above and resolves them into a
  configuration.

  Returns `{:ok, config}`, or `{:error, reason}` naming the first fault:
  an unknown option, then a missing or malformed `:repo`, then a malformed
  `:delivery`, then a missing or malformed `:store`, `:executor`,
  `:resolver` or `:chart_resolver`, in that order, then a `:store` whose
  adapter options name another repo, then a malformed
  `:persistence_options`, then a storage value the
  table does not allow, then the first binding
  `StatifierRouter.Binding.new/1` refuses, as `{:binding, index, reason}`
  with `index` counted from zero, then the first duplicated binding `id`.

      iex> StatifierRouter.Config.new(repo: MyApp.Repo, delivery: MyApp.Delivery, table_prefix: 7)
      {:error, {:invalid_value, :table_prefix, 7}}
      iex> StatifierRouter.Config.new(repo: MyApp.Repo)
      {:error, {:missing_key, :store}}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, new_error()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) || {:error, {:invalid_config, opts}},
         :ok <- reject_unknown(opts, @known),
         {:ok, repo} <- fetch_module(opts, :repo),
         {:ok, delivery} <- fetch_delivery(opts),
         {:ok, needs} <- delivery_needs(opts, delivery),
         :ok <- same_repo(needs[:store], repo),
         {:ok, persistence_options} <- persistence_options(opts),
         {:ok, storage} <- storage(opts),
         {:ok, bindings} <- bindings(opts) do
      {:ok,
       struct!(
         __MODULE__,
         [
           {:repo, repo},
           {:delivery, delivery},
           {:bindings, bindings},
           {:persistence_options, persistence_options} | needs ++ storage
         ]
       )}
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
      {:ok, value} ->
        if module?(value), do: {:ok, value}, else: {:error, {:invalid_value, name, value}}

      :error ->
        {:error, {:missing_key, name}}
    end
  end

  defp fetch_delivery(opts) do
    case Keyword.fetch(opts, :delivery) do
      :error -> {:ok, StatifierRouter.Delivery}
      {:ok, _module} -> fetch_module(opts, :delivery)
    end
  end

  # The four options StatifierRouter.Delivery requires. They are required when
  # it is the delivery module, and checked whenever they are given.
  defp delivery_needs(opts, delivery) do
    required? = delivery == StatifierRouter.Delivery

    Enum.reduce_while(@delivery_keys, {:ok, []}, fn name, {:ok, acc} ->
      case delivery_need(name, Keyword.fetch(opts, name), required?) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [{name, value} | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp delivery_need(name, {:ok, value}, _required?) do
    if delivery_value?(name, value),
      do: {:ok, value},
      else: {:error, {:invalid_value, name, value}}
  end

  defp delivery_need(name, :error, true), do: {:error, {:missing_key, name}}
  defp delivery_need(_name, :error, false), do: {:ok, nil}

  defp delivery_value?(:store, value), do: is_struct(value, Storage)
  defp delivery_value?(:executor, value) when is_function(value, 2), do: true
  defp delivery_value?(:executor, value), do: module?(value)
  defp delivery_value?(:resolver, value), do: StatifierRouter.Resolver.valid?(value)
  defp delivery_value?(:chart_resolver, value), do: is_function(value, 1)

  # ADR-0003, section 1: the store has to write through the delivery's own
  # transaction, which it does only when it is built over the same repo.
  # Only statifier_persistence's Ecto storage resolves a `:repo` into its
  # adapter options, so this refuses the mismatch it can see and passes
  # everything else through; the moduledoc says so.
  defp same_repo(%Storage{opts: opts} = store, repo) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :repo) and
         Keyword.fetch!(opts, :repo) != repo,
       do: {:error, {:invalid_value, :store, store}},
       else: :ok
  end

  defp same_repo(_store, _repo), do: :ok

  # The per-call snapshot options StatifierRouter.Delivery carries onto
  # every create and every step. Only the keys this package knows how to
  # place are accepted: `:initialize` and `:metadata` are per-execution
  # host data rather than a standing snapshot, and `:executor` is the
  # configuration's own option.
  defp persistence_options(opts) do
    given = Keyword.get(opts, :persistence_options, [])

    if snapshot?(given),
      do: {:ok, given},
      else: {:error, {:invalid_value, :persistence_options, given}}
  end

  defp snapshot?(given) do
    is_list(given) and Keyword.keyword?(given) and
      Enum.all?(given, fn {name, _value} -> name in @persistence_option_keys end)
  end

  defp module?(value), do: is_atom(value) and not is_nil(value) and not is_boolean(value)

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
