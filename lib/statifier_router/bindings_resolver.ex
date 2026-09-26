defmodule StatifierRouter.BindingsResolver do
  @moduledoc """
  The host's answer to which bindings an event is routed by under a scope
  (ADR-0001, the Amendment of 2026-09-25).

  A configuration's `:bindings` is one list for every scope. A host whose
  bindings differ by scope - each scope routing its own sources to its own
  documents - gives the configuration a `:bindings_resolver` instead. It
  takes the event's `scope` and answers the list of
  `%StatifierRouter.Binding{}` structs that scope routes by, in the order
  `StatifierRouter.route/3` returns its outcomes in. The two keys are
  exclusive: `StatifierRouter.Config.new/1` refuses a configuration that
  gives both.

  A bindings resolver is a module implementing this behaviour, the
  documented form, or an arity-1 fun with
  `c:StatifierRouter.BindingsResolver.resolve/1`'s own signature, accepted
  wherever a module is. A host that keeps its bindings in its own tables
  builds each one with `StatifierRouter.Binding.new/1` and answers the
  structs:

      defmodule MyApp.ScopedBindings do
        @behaviour StatifierRouter.BindingsResolver

        @impl StatifierRouter.BindingsResolver
        def resolve(scope) do
          MyApp.Routing.bindings_for(scope)
        end
      end

  It is called with a scope in hand, each time one is: once per
  `StatifierRouter.route/3` call, once per `StatifierRouter.Broadway`
  partition, and once per `StatifierRouter.subscribe/3` of a subscribing
  execution's scope. Nothing here caches the answer; caching is the host's,
  and a host that builds its bindings from rows will want to, because
  `StatifierRouter.Binding.new/1` compiles two predicator programs per
  binding.

  Each answer is checked as `:bindings` is at `StatifierRouter.Config.new/1`,
  each time it is given: a binding whose `id` is the reserved name
  `StatifierRouter.SendHandler.execution_target/0` is refused as
  `{:reserved_binding_id, name}`, and a duplicated `id` as
  `{:duplicate_binding_id, id}`. An answer that is not a list of
  `%StatifierRouter.Binding{}` structs raises `ArgumentError`, as a
  malformed `StatifierRouter.Resolver` answer does. `StatifierRouter.Broadway`'s
  partitioner rescues that raise and hashes the message id, and
  `route/3` raises it again where the message fails.

  What each caller does with a refused answer:

    * `StatifierRouter.route/3` returns the refusal as `{:error, reason}`
      before any binding is evaluated, so nothing is written and a front
      does not acknowledge the event;
    * `StatifierRouter.Broadway`'s partitioner hashes the message id, as it
      does for any message it cannot address, and `route/3` then fails the
      message;
    * `StatifierRouter.subscribe/3` raises `ArgumentError` naming the
      refusal, because its return names no such refusal.

  The publish-time checks and the address reaper take no scope and never
  call a bindings resolver: `StatifierRouter.Contracts.check/3` reads the
  configuration's `bindings: []`, so a host checks its bindings per scope
  with `StatifierRouter.Contracts.undeclared_binding_events/2`, and
  `StatifierRouter.Addresses.reap/3` computes its horizons from the
  bindings the host hands it.
  """

  alias StatifierRouter.Binding

  @typedoc """
  A bindings resolver: a module implementing this behaviour, or an arity-1
  fun with `c:StatifierRouter.BindingsResolver.resolve/1`'s own signature.
  """
  @type t :: module() | (scope :: String.t() -> [Binding.t()])

  @doc """
  The bindings events under `scope` are routed by, in routing order.
  """
  @callback resolve(scope :: String.t()) :: [Binding.t()]

  # Package-internal: normalizes the module-or-fun shapes of t:t/0 into one
  # call, and checks the answer is a list of built bindings.
  # StatifierRouter.Config.bindings_for/2 is the only intended caller.
  @doc false
  @spec call(t(), String.t()) :: [Binding.t()]
  def call(resolver, scope) do
    resolver
    |> answer(scope)
    |> check_answer(resolver, scope)
  end

  defp answer(resolver, scope) when is_atom(resolver), do: resolver.resolve(scope)
  defp answer(resolver, scope) when is_function(resolver, 1), do: resolver.(scope)

  defp check_answer(answer, resolver, scope) do
    if is_list(answer) and Enum.all?(answer, &is_struct(&1, Binding)) do
      answer
    else
      raise ArgumentError,
            "the bindings resolver #{inspect(resolver)} answered #{inspect(answer)} " <>
              "for the scope #{inspect(scope)}; expected a list of %StatifierRouter.Binding{}"
    end
  end

  # Package-internal: whether `value` is one of t:t/0's shapes. A module
  # must be loadable and export resolve/1.
  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_function(value, 1), do: true

  def valid?(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Code.ensure_loaded?(value) and function_exported?(value, :resolve, 1)

  def valid?(_value), do: false
end
