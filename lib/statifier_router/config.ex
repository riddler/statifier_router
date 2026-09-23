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
  | `:route_adapters` | the route registry, a map from route name to `{module, config}` where the module implements `StatifierRouter.Route` | `%{}` |
  | `:route_overrides` | a map from scope to a map from route name to a configuration, merged over that route's registered configuration in that scope | `%{}` |
  | `:send_type` | the one `<send>` type string `StatifierRouter.SendHandler` answers to | `nil` |
  | `:on_complete` | the name of a registered route an execution's donedata is handed to on the delivery that finishes it; an `{:error, _}` from that route rolls the delivery back, finishing step included, so a route that never succeeds keeps the execution from finishing (see below) | `nil` |
  | `:timer_queue` | `{module, config}` where the module implements `StatifierRouter.TimerQueue` | `nil` |
  | `:table_prefix` | a string prefixed to every table name | `"statifier_router_"` |
  | `:prefix` | the Postgres schema the tables live in, as a string | `nil` (the repo's default) |

  `StatifierRouter` documents what a delivery module must answer, and
  `StatifierRouter.Delivery` what the four options it requires must be.
  A configuration that names another delivery module may leave those four
  out; one it gives is checked all the same. `:persistence_options` is
  never required: a configuration that omits it carries no snapshot, which
  is what statifier_persistence reads as "the built-in set only".

  ## The route registry, and the two `routes` on this struct

  `:route_adapters` is ADR-0005 decision 2's registry: the named outbound
  destinations a chart reaches with `<send target="...">`, each mapped to
  the module that serves it. It is deliberately **not** spelled `:routes`.
  `:routes` already means something else here - it is one of
  `:persistence_options`, where it is `Statifier.Send.Routes`, the
  engine's point-in-time claim about which `<send>` routes are live - and
  ADR-0005 decision 6 closed that ambiguity by vocabulary rather than by
  renaming the engine's. `route/3` resolves a name in a scope.

  `:send_type` is the one type string `StatifierRouter.SendHandler` is
  registered under. Giving it is what puts `send_types:` into
  `:persistence_options`, as the `Statifier.Send.Types` snapshot built
  from that type string and that handler (ADR-0005, decision 6); the
  registry cannot supply it, because a registry maps a route name to an
  adapter and holds no type string. A configuration that gives both
  `:send_type` and a `:send_types` of its own is refused with
  `{:declared_send_types, send_type}` rather than one silently winning.

  `:on_complete` names one route in that same registry, and a name absent
  from `:route_adapters` is refused with `{:unregistered_on_complete,
  name}` rather than missed on the one delivery that would have used it.
  It is what `StatifierRouter.Delivery` hands an execution's donedata to
  on the delivery that finishes the execution, inside that delivery's
  transaction; the README's "A finished execution reaches a sink" sets it
  beside the chart's own way of telling a sink.

  An `{:error, reason}` from that route settles the delivery as
  `{:error, {:on_complete, route_name, reason}}` and rolls it back, the
  finishing step with it (ADR-0003, section 1). That is deliberate: a
  terminal execution has no `error.communication` transition left to
  take, so rolling back is the only way the hand-off is not lost. Its
  consequence is that **a route that never succeeds is a poison pill**.
  The delivery that would finish the execution never commits, so the
  execution stays at the position it held before that step; each time the
  source hands the same message over again, the step runs again, its
  effects reach the executor again, the route is called again and the
  delivery fails again, and the front sees a message that fails every
  time. An execution that would finish on `create/4` is rolled back whole
  instead, and each new attempt creates it under a new execution id
  (ADR-0003, section 2). The route must therefore be safe to call again
  under the same idempotency key - the at-most-once obligation
  `StatifierRouter.Route` states - and must eventually succeed. Nothing in
  this package retries or holds a failed message, so the number of
  attempts is bounded only by the source's own redelivery policy (the
  producer's contract, `StatifierRouter.Broadway`'s "Redelivery is the
  producer's contract").

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

  Each binding given as a map or keyword list is built with
  `StatifierRouter.Binding.new/1`. The resolved configuration keeps the
  bindings in the order given: it is the order
  `StatifierRouter.route/3` returns its outcomes in. A duplicate binding
  `id` is a fault of the list rather than of any one binding, so it is
  refused here, naming the duplicated `id`, before any event is routed
  (ADR-0001, section 1).

  A `%StatifierRouter.Binding{}` in the list is trusted as
  `StatifierRouter.Binding.new/1` built it and kept as given: it is not
  passed through `StatifierRouter.Binding.new/1` again, so its programs
  are not recompiled and its fields are not re-checked. A struct built or
  altered any other way is the host's to keep valid. The two checks on
  the list as a whole, the reserved `id` and the duplicated `id`, apply to
  it all the same.

  The four tables are the address table of ADR-0002 (`addresses`), the
  dedupe table of ADR-0003 (`dedupe`), the ledger of ADR-0004
  (`routing_ledger`) and the subscription table of ADR-0007
  (`subscriptions`); `table/2` names each one under a configuration.
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

  alias Statifier.Send.Types
  alias StatifierPersistence.Storage
  alias StatifierRouter.Binding
  alias StatifierRouter.Route
  alias StatifierRouter.Schema
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TimerQueue

  @enforce_keys [:repo, :delivery]
  defstruct [
    :repo,
    :delivery,
    :store,
    :executor,
    :resolver,
    :chart_resolver,
    :prefix,
    :send_type,
    :on_complete,
    :timer_queue,
    bindings: [],
    persistence_options: [],
    route_adapters: %{},
    route_overrides: %{},
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
          route_adapters: %{optional(String.t()) => Route.t()},
          route_overrides: %{optional(String.t()) => %{optional(String.t()) => map()}},
          send_type: String.t() | nil,
          on_complete: String.t() | nil,
          timer_queue: TimerQueue.t() | nil,
          table_prefix: String.t(),
          prefix: String.t() | nil
        }

  @typedoc "One of the four tables this package owns."
  @type table :: :addresses | :dedupe | :routing_ledger | :subscriptions

  @typedoc "Why `new/1` refused a configuration."
  @type new_error ::
          {:unknown_key, term()}
          | {:missing_key, :repo | :store | :executor | :resolver | :chart_resolver}
          | {:invalid_value, atom(), term()}
          | {:invalid_config, term()}
          | {:binding, non_neg_integer(), Binding.new_error()}
          | {:duplicate_binding_id, String.t()}
          | {:unregistered_route, String.t(), String.t()}
          | {:declared_send_types, String.t()}
          | {:unregistered_on_complete, String.t()}
          | {:reserved_route, String.t()}
          | {:reserved_binding_id, String.t()}

  @tables [:addresses, :dedupe, :routing_ledger, :subscriptions]
  @storage_keys [:table_prefix, :prefix]
  @delivery_keys [:store, :executor, :resolver, :chart_resolver]
  @persistence_option_keys [:routes, :invoke_types, :send_types]
  @route_keys [:route_adapters, :route_overrides, :send_type, :on_complete, :timer_queue]
  @known [
    :repo,
    :delivery,
    :bindings,
    :persistence_options | @delivery_keys ++ @storage_keys ++ @route_keys
  ]

  @schemas %{
    Schema.Address => :addresses,
    Schema.Dedupe => :dedupe,
    Schema.Ledger => :routing_ledger,
    Schema.Subscription => :subscriptions
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
  with `index` counted from zero, then a binding whose `id` is the
  reserved name, then the first duplicated binding `id`.

  An `:on_complete` naming a route the host did not register is refused
  with `{:unregistered_on_complete, name}`, after the registry itself is
  resolved.

  ADR-0006, section 1 reserves one name for the execution target,
  `StatifierRouter.SendHandler.execution_target/0`. A `:route_adapters`
  entry under it is refused with `{:reserved_route, name}`, after the
  registry's own shape is checked, and a binding whose `id` is it with
  `{:reserved_binding_id, name}`.

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
         {:ok, routes} <- routes(opts),
         {:ok, persistence_options} <- persistence_options(opts, routes[:send_type]),
         {:ok, storage} <- storage(opts),
         {:ok, bindings} <- bindings(opts) do
      {:ok,
       struct!(
         __MODULE__,
         [
           {:repo, repo},
           {:delivery, delivery},
           {:bindings, bindings},
           {:persistence_options, persistence_options} | needs ++ storage ++ routes
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
  The adapter serving the route `name` under `scope`, with that scope's
  override applied over the adapter's registered configuration, or
  `:error` when the host registered no such route (ADR-0005, decision 2).

  A scope overrides a route's configuration and never its existence, so a
  name absent from `:route_adapters` misses in every scope, and a `scope`
  of `nil` - a caller with no scope in reach - resolves the registered
  configuration unchanged.
  """
  @spec route(t(), String.t() | nil, String.t() | nil) :: {:ok, Route.t()} | :error
  def route(%__MODULE__{} = config, scope, name) when is_binary(name) do
    case Map.fetch(config.route_adapters, name) do
      {:ok, {module, registered}} ->
        {:ok, {module, Map.merge(registered, override(config, scope, name))}}

      :error ->
        :error
    end
  end

  def route(%__MODULE__{}, _scope, _name), do: :error

  defp override(_config, nil, _name), do: %{}

  defp override(%__MODULE__{route_overrides: overrides}, scope, name) do
    overrides
    |> Map.get(scope, %{})
    |> Map.get(name, %{})
  end

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
  defp persistence_options(opts, send_type) do
    given = Keyword.get(opts, :persistence_options, [])

    cond do
      not snapshot?(given) -> {:error, {:invalid_value, :persistence_options, given}}
      is_nil(send_type) -> {:ok, given}
      Keyword.has_key?(given, :send_types) -> {:error, {:declared_send_types, send_type}}
      true -> {:ok, given ++ [send_types: send_types(send_type)]}
    end
  end

  # ADR-0005 decision 6: the snapshot is built from the handler module and
  # the type string it is registered under, never from the route registry,
  # which maps a route name to an adapter and holds no type string at all.
  defp send_types(send_type),
    do: Types.from_send_types(%{send_type => SendHandler})

  # ADR-0005 decision 2's registry, and the one type string decision 6's
  # snapshot is built from. An override may change a registered route's
  # configuration and may not add or remove a route, so an override naming
  # a route the host did not register is refused here rather than missed
  # at run time.
  defp routes(opts) do
    with {:ok, adapters} <- route_adapters(opts),
         {:ok, overrides} <- route_overrides(opts, adapters),
         {:ok, send_type} <- send_type(opts),
         {:ok, on_complete} <- on_complete(opts, adapters),
         {:ok, timer_queue} <- timer_queue(opts) do
      {:ok,
       [
         route_adapters: adapters,
         route_overrides: overrides,
         send_type: send_type,
         on_complete: on_complete,
         timer_queue: timer_queue
       ]}
    end
  end

  # ADR-0006, section 1 reserves one route name: a chart that writes it in
  # `target` always means the execution target and never a host transport,
  # which only holds if the host cannot register a route under it. The
  # refusal is here, at configuration time, so no chart discovers it at run
  # time.
  defp route_adapters(opts) do
    given = Keyword.get(opts, :route_adapters, %{})
    reserved = SendHandler.execution_target()

    cond do
      not (is_map(given) and Enum.all?(given, &route_adapter?/1)) ->
        {:error, {:invalid_value, :route_adapters, given}}

      Map.has_key?(given, reserved) ->
        {:error, {:reserved_route, reserved}}

      true ->
        {:ok, given}
    end
  end

  defp route_adapter?({name, {module, config}}),
    do: is_binary(name) and name != "" and Route.valid?(module) and is_map(config)

  defp route_adapter?(_entry), do: false

  defp route_overrides(opts, adapters) do
    given = Keyword.get(opts, :route_overrides, %{})

    if is_map(given) and Enum.all?(given, &scope_override?/1),
      do: unregistered_override(given, adapters),
      else: {:error, {:invalid_value, :route_overrides, given}}
  end

  defp scope_override?({scope, by_name}) do
    is_binary(scope) and scope != "" and is_map(by_name) and
      Enum.all?(by_name, fn {name, config} ->
        is_binary(name) and name != "" and is_map(config)
      end)
  end

  defp scope_override?(_entry), do: false

  defp unregistered_override(given, adapters) do
    given
    |> Enum.flat_map(fn {scope, by_name} ->
      Enum.map(by_name, fn {name, _} -> {scope, name} end)
    end)
    |> Enum.find(fn {_scope, name} -> not Map.has_key?(adapters, name) end)
    |> case do
      nil -> {:ok, given}
      {scope, name} -> {:error, {:unregistered_route, scope, name}}
    end
  end

  defp send_type(opts) do
    case Keyword.get(opts, :send_type) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_value, :send_type, value}}
    end
  end

  # The completion hook's route. It is resolved against the registry here,
  # at configuration time, because the delivery that would use it is the
  # one that finishes an execution: a name checked only at run time would
  # miss on the single delivery that had something to hand over, and there
  # is no second chance at a completion. The reserved execution-target name
  # can never be a registry entry (`route_adapters/1` refuses it), so it is
  # refused here as an unregistered name.
  defp on_complete(opts, adapters) do
    case Keyword.get(opts, :on_complete) do
      nil ->
        {:ok, nil}

      name when is_binary(name) and name != "" ->
        if Map.has_key?(adapters, name),
          do: {:ok, name},
          else: {:error, {:unregistered_on_complete, name}}

      value ->
        {:error, {:invalid_value, :on_complete, value}}
    end
  end

  defp timer_queue(opts) do
    case Keyword.get(opts, :timer_queue) do
      nil ->
        {:ok, nil}

      {module, config} = value ->
        if TimerQueue.valid?(module) and is_map(config),
          do: {:ok, value},
          else: {:error, {:invalid_value, :timer_queue, value}}

      value ->
        {:error, {:invalid_value, :timer_queue, value}}
    end
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
             :ok <- refuse_reserved_id(bindings),
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

  # The other half of ADR-0006, section 1's reserved name: the ledger row
  # of an execution-to-execution send carries it as `binding_id`, so a host
  # binding under that id would write rows a reader cannot tell from those.
  defp refuse_reserved_id(bindings) do
    reserved = SendHandler.execution_target()

    if Enum.any?(bindings, &(&1.id == reserved)),
      do: {:error, {:reserved_binding_id, reserved}},
      else: :ok
  end

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
