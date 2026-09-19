defmodule StatifierRouter.Binding do
  @moduledoc """
  A binding: the declaration that routes an event from a source to one
  execution of one document, as ADR-0001 fixes it.

  A binding says which events it wants (`match`), how to compute the key
  that names one execution among many (`key`), which document that
  execution belongs to (`document`), which chart event the execution is
  handed (`event`), and which fields of the event travel with it (`data`).

  ## Construction

  `new/1` takes a map or keyword list whose keys are atoms from this table
  (ADR-0001, section 1) and returns `{:ok, binding}` or `{:error, reason}`:

  | Key | Value | Default |
  |---|---|---|
  | `:id` | a non-empty string | required |
  | `:source` | a string | required |
  | `:selector` | a map | `%{}` |
  | `:match` | a predicator program, as a string | required |
  | `:key` | a predicator program, as a string | required |
  | `:document` | a non-empty string | required |
  | `:event` | a non-empty string | required |
  | `:data` | a list of dotted field paths, as strings | `[]` |
  | `:create` | `:if_absent`, `:never` or `:always_new` | `:if_absent` |
  | `:dedupe` | `%{by: :message_id, horizon_ms: h}`, `h` a positive integer | `%{by: :message_id, horizon_ms: 259_200_000}` |
  | `:order` | `:by_key` or `:none` | `:by_key` |
  | `:enabled` | a boolean | `true` |

  Every fault that can be seen without an event is refused here, in this
  order: a reserved key (`mode`, `batch` or `window`, ADR-0001 section 6)
  before any other check, then an unknown key, then a missing required key,
  then a value the table does not allow, then a `match` or `key` that
  predicator does not compile (ADR-0001 section 2). `match` and `key` are
  compiled once, here, and kept compiled.

  A duplicate `id` among several bindings is a fault of the configuration
  that holds them, not of one binding, so `new/1` does not look for it.

  ## Evaluation

  `match/2` and `key/2` evaluate the compiled programs over the normalized
  event, a string-keyed map bound in the predicator context as `event`, so
  a program reads `event.kind` or `event.impression_id`.

    * `match/2` returns `true` only when the program evaluates to exactly
      `true`. `false` and `nil` return `false`, and `:undefined` returns
      `:undefined`: all three mean the event is not for this binding. An
      evaluation error, or any other value, is `{:refused, reason}`
      (ADR-0001 section 2).
    * `key/2` returns `{:ok, key}` when the program evaluates to a
      non-empty string, and `{:refused, reason}` for anything else
      (ADR-0001 section 3).

  `project/2` builds the delivered event's data from the `data` paths
  (ADR-0001 section 5).

  ## Example

      iex> {:ok, binding} =
      ...>   StatifierRouter.Binding.new(
      ...>     id: "clicks_to_join",
      ...>     source: "ad_events",
      ...>     match: "event.kind == 'click'",
      ...>     key: "event.impression_id",
      ...>     document: "impression_click_join",
      ...>     event: "click",
      ...>     data: ["impression_id", "url"]
      ...>   )
      iex> click = %{"kind" => "click", "impression_id" => "imp_7f3a"}
      iex> StatifierRouter.Binding.match(binding, click)
      true
      iex> StatifierRouter.Binding.key(binding, click)
      {:ok, "imp_7f3a"}
      iex> StatifierRouter.Binding.project(binding, click)
      %{"impression_id" => "imp_7f3a"}
  """

  @enforce_keys [:id, :source, :match, :key, :document, :event, :compiled_match, :compiled_key]
  defstruct [
    :id,
    :source,
    :match,
    :key,
    :document,
    :event,
    :compiled_match,
    :compiled_key,
    selector: %{},
    data: [],
    create: :if_absent,
    dedupe: %{by: :message_id, horizon_ms: 259_200_000},
    order: :by_key,
    enabled: true
  ]

  @typedoc "A predicator instruction list, as `Predicator.compile/1` returns it."
  @type program :: list()

  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          selector: map(),
          match: String.t(),
          key: String.t(),
          document: String.t(),
          event: String.t(),
          data: [String.t()],
          create: :if_absent | :never | :always_new,
          dedupe: %{by: :message_id, horizon_ms: pos_integer()},
          order: :by_key | :none,
          enabled: boolean(),
          compiled_match: program(),
          compiled_key: program()
        }

  @typedoc "Why `new/1` refused a binding."
  @type new_error ::
          {:reserved_key, term()}
          | {:unknown_key, term()}
          | {:duplicate_key, atom()}
          | {:missing_key, atom()}
          | {:invalid_value, atom(), term()}
          | {:match, struct()}
          | {:key, struct()}
          | {:invalid_binding, term()}

  @typedoc "Why `match/2` or `key/2` refused an event for this binding."
  @type refusal ::
          {:evaluation_error, struct()}
          | {:non_boolean, term()}
          | {:invalid_key, term()}

  @reserved [:mode, :batch, :window]
  @reserved_names Enum.map(@reserved, &Atom.to_string/1)
  @required [:id, :source, :match, :key, :document, :event]
  @optional [:selector, :data, :create, :dedupe, :order, :enabled]
  @known @required ++ @optional

  @doc """
  Builds a binding from a map or keyword list with atom keys, validating
  every key and value and compiling `match` and `key` once.

  Returns `{:ok, binding}`, or `{:error, reason}` naming the first fault
  found, in the order the moduledoc gives.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, new_error()}
  def new(attrs) when is_map(attrs) do
    pairs = Map.to_list(attrs)

    with :ok <- refuse_reserved(pairs),
         :ok <- refuse_unknown(pairs),
         :ok <- require_keys(attrs),
         :ok <- validate_values(attrs),
         {:ok, compiled_match} <- compile(:match, attrs.match),
         {:ok, compiled_key} <- compile(:key, attrs.key) do
      fields =
        attrs
        |> Map.put(:compiled_match, compiled_match)
        |> Map.put(:compiled_key, compiled_key)

      {:ok, struct!(__MODULE__, fields)}
    end
  end

  def new(attrs) when is_list(attrs) do
    with :ok <- refuse_reserved(attrs),
         :ok <- keyword_shape(attrs),
         :ok <- refuse_duplicates(attrs) do
      new(Map.new(attrs))
    end
  end

  def new(other), do: {:error, {:invalid_binding, other}}

  @doc """
  Evaluates the binding's `match` over the normalized event.

  Returns `true` when the program evaluates to exactly `true`; `false` when
  it evaluates to `false` or `nil`; `:undefined` when it evaluates to
  `:undefined`. The last two mean the event is not for this binding.
  Returns `{:refused, reason}` when the evaluation returns an error or any
  other value.
  """
  @spec match(t(), map()) :: true | false | :undefined | {:refused, refusal()}
  def match(%__MODULE__{compiled_match: program}, event) when is_map(event) do
    case evaluate(program, event) do
      {:ok, true} -> true
      {:ok, false} -> false
      {:ok, nil} -> false
      {:ok, :undefined} -> :undefined
      {:ok, other} -> {:refused, {:non_boolean, other}}
      {:error, error} -> {:refused, {:evaluation_error, error}}
    end
  end

  @doc """
  Evaluates the binding's `key` over the normalized event.

  Returns `{:ok, key}` when the program evaluates to a non-empty string.
  Anything else - `:undefined`, `nil`, the empty string, a number, any other
  value, or an evaluation error - is `{:refused, reason}`.
  """
  @spec key(t(), map()) :: {:ok, String.t()} | {:refused, refusal()}
  def key(%__MODULE__{compiled_key: program}, event) when is_map(event) do
    case evaluate(program, event) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      {:ok, other} -> {:refused, {:invalid_key, other}}
      {:error, error} -> {:refused, {:evaluation_error, error}}
    end
  end

  @doc """
  Builds the delivered event's data: each of the binding's `data` paths,
  read from the normalized event and written under the same path.

  A dotted path reads and writes nested maps, so `"placement.slot"` carries
  `%{"placement" => %{"slot" => value}}`. A path the event does not carry
  is left out, and nothing outside the listed paths is delivered.
  """
  @spec project(t(), map()) :: map()
  def project(%__MODULE__{data: paths}, event) when is_map(event) do
    Enum.reduce(paths, %{}, fn path, acc ->
      segments = String.split(path, ".")

      case fetch_path(event, segments) do
        {:ok, value} -> put_path(acc, segments, value)
        :error -> acc
      end
    end)
  end

  # -- construction ---------------------------------------------------------

  defp refuse_reserved(pairs) do
    case Enum.find(pairs, &reserved?/1) do
      nil -> :ok
      {name, _value} -> {:error, {:reserved_key, name}}
    end
  end

  defp reserved?({name, _value}) when is_atom(name), do: name in @reserved
  defp reserved?({name, _value}) when is_binary(name), do: name in @reserved_names
  defp reserved?(_other), do: false

  defp keyword_shape(attrs) do
    if Keyword.keyword?(attrs), do: :ok, else: {:error, {:invalid_binding, attrs}}
  end

  defp refuse_duplicates(attrs) do
    attrs
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {name, _count} -> {:error, {:duplicate_key, name}}
    end
  end

  defp refuse_unknown(pairs) do
    case Enum.find(pairs, fn {name, _value} -> name not in @known end) do
      nil -> :ok
      {name, _value} -> {:error, {:unknown_key, name}}
    end
  end

  defp require_keys(attrs) do
    case Enum.find(@required, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      name -> {:error, {:missing_key, name}}
    end
  end

  defp validate_values(attrs) do
    Enum.find_value(@known, :ok, fn name ->
      with {:ok, value} <- Map.fetch(attrs, name),
           false <- valid?(name, value) do
        {:error, {:invalid_value, name, value}}
      else
        _present_and_valid_or_absent -> nil
      end
    end)
  end

  defp valid?(name, value) when name in [:id, :document, :event], do: non_empty_string?(value)
  defp valid?(name, value) when name in [:source, :match, :key], do: is_binary(value)
  defp valid?(:selector, value), do: is_map(value)
  defp valid?(:data, value), do: is_list(value) and Enum.all?(value, &data_path?/1)
  defp valid?(:create, value), do: value in [:if_absent, :never, :always_new]
  defp valid?(:order, value), do: value in [:by_key, :none]
  defp valid?(:enabled, value), do: is_boolean(value)

  defp valid?(:dedupe, %{by: :message_id, horizon_ms: horizon} = value)
       when map_size(value) == 2,
       do: is_integer(horizon) and horizon > 0

  defp valid?(:dedupe, _value), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp data_path?(path) do
    is_binary(path) and path |> String.split(".") |> Enum.all?(&(&1 != ""))
  end

  defp compile(name, source) do
    case Predicator.compile(source) do
      {:ok, program} -> {:ok, program}
      {:error, error} -> {:error, {name, error}}
    end
  end

  # -- evaluation -----------------------------------------------------------

  # No options are passed, so none of predicator's option checks (the ones
  # that raise on a caller's malformed option) can be reached from here;
  # every predicate-derived failure comes back as {:error, error}.
  defp evaluate(program, event), do: Predicator.evaluate(program, %{"event" => event})

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [segment | rest]) when is_map(map) do
    case Map.fetch(map, segment) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_not_a_map, _segments), do: :error

  defp put_path(acc, [segment], value), do: Map.put(acc, segment, value)

  defp put_path(acc, [segment | rest], value) do
    inner =
      case Map.get(acc, segment) do
        map when is_map(map) -> map
        _absent -> %{}
      end

    Map.put(acc, segment, put_path(inner, rest, value))
  end
end
