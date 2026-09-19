defmodule StatifierRouter.Resolver.Static do
  @moduledoc """
  A resolver over a fixed map of compiled charts, for tests and for a host
  whose charts are compiled at boot.

  `new/1` takes a map from `{scope, document}` to the `Statifier.Machine`
  new executions of that document start on under that scope, and returns
  a resolver in the arity-2 fun form `StatifierRouter.Resolver` accepts:

      iex> {:ok, machine} =
      ...>   Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="done"><final id="done"/></scxml>))
      iex> {:ok, resolver} =
      ...>   StatifierRouter.Resolver.Static.new(%{{"7c1e", "impression_click_join"} => machine})
      iex> {"sha256:" <> _, ^machine} = resolver.("7c1e", "impression_click_join")
      iex> resolver.("91ab", "impression_click_join")
      {:error, :not_found}

  The resolver answers `{content_hash, machine}` for a pair in the map, the
  content hash being `Statifier.Machine.identity/1`'s, which is the hash
  statifier_persistence records for an execution created on that machine.
  A pair the map does not hold answers `{:error, :not_found}`. The map is
  fixed when `new/1` builds the resolver: a host that publishes new
  revisions while it runs implements `c:StatifierRouter.Resolver.resolve/2`
  over its own store instead.

  Every machine must carry the identity `Statifier.compile/2` stamps, since
  statifier_persistence refuses to create an execution on a machine
  without one. `new/1` refuses the first entry that breaks a rule, in the
  map's iteration order: `{:invalid_entry, entry}` for a key that is not a
  `{scope, document}` pair of strings or a value that is not a
  `%Statifier.Machine{}`, and `{:unidentified_chart, {scope, document}}` for
  a machine with no identity.
  """

  alias Statifier.Machine

  @typedoc "Why `new/1` refused a map."
  @type new_error ::
          {:invalid_entry, term()}
          | {:unidentified_chart, {String.t(), String.t()}}
          | {:invalid_charts, term()}

  @doc """
  Builds a resolver over `charts`, a map from `{scope, document}` to a
  compiled machine, as the module documentation describes.
  """
  @spec new(%{optional({String.t(), String.t()}) => Machine.t()}) ::
          {:ok, StatifierRouter.Resolver.t()} | {:error, new_error()}
  def new(charts) when is_map(charts) do
    Enum.reduce_while(charts, {:ok, %{}}, fn entry, {:ok, acc} ->
      case entry(entry) do
        {:ok, pair, answer} -> {:cont, {:ok, Map.put(acc, pair, answer)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, answers} -> {:ok, resolver(answers)}
      error -> error
    end
  end

  def new(other), do: {:error, {:invalid_charts, other}}

  defp entry({{scope, document} = pair, %Machine{} = machine})
       when is_binary(scope) and is_binary(document) do
    case Machine.identity(machine) do
      nil -> {:error, {:unidentified_chart, pair}}
      identity -> {:ok, pair, {identity.content_hash, machine}}
    end
  end

  defp entry(entry), do: {:error, {:invalid_entry, entry}}

  defp resolver(answers) do
    fn scope, document ->
      case Map.fetch(answers, {scope, document}) do
        {:ok, answer} -> answer
        :error -> {:error, :not_found}
      end
    end
  end
end
