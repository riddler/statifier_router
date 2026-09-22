defmodule StatifierRouter.Route do
  @moduledoc """
  The behaviour a host implements for one named outbound destination
  (ADR-0005, decision 2). A chart names a route in a `<send>`'s `target`
  under a type the host registered, and
  `StatifierRouter.SendHandler` hands the built event to the module
  registered for that name.

      <send type="myapp:sink" target="joined_records" event="joined">
        <param name="impression_id" expr="impression_id"/>
      </send>

  ## A route is one-way

  `c:deliver/3` answers `:ok` or `{:error, term()}` - handed off, or not
  handed off - and returns no data (ADR-0005, decision 3). A sink's
  result comes back as a new inbound event through a binding
  (ADR-0001), never as this callback's return. The one thing an
  `{:error, _}` causes in the sending execution is `error.communication`
  carrying the send's `sendid`, which is transport failure rather than an
  answer, and an adapter that swallows its own errors and answers `:ok`
  removes that transition from every chart on its route.

  ## What a route may do where it is called

  At `StatifierPersistence.Executor.execute/2` a route runs inside the
  delivery's transaction, under the execution's lock, so it may **only
  hand off durably**: a job inserted on the host's own repo from the
  calling process joins that transaction, which is a transactional
  outbox and closes ADR-0003 section 2's window where a rollback does not
  un-fire what the executor was handed. A route called there must never
  call `StatifierRouter.route/3`,
  `StatifierPersistence.Executions.step/5` or any other door of the
  sending execution; `StatifierRouter.Delivery.deliver/4` refuses the
  call it can see, and `StatifierRouter.SendHandler`'s own documentation
  says what that refusal does and does not reach.

  ## Idempotency

  Neither host shape supplies an idempotency key, so the router composes
  one (ADR-0005, decision 4) and hands it over as `t:idempotency_key/0`.
  A route owes at-most-once on it. Effect execution is at-least-once: a
  crash between the step and the write re-drives the same event and
  re-emits the same effects with identical deterministic fields, and a
  delivery that rolled back is redriven the same way.

  ## Adapter configuration

  The first argument is the route's own configuration, as the host
  registered it under `StatifierRouter.Config`'s `:route_adapters`, with
  any `:route_overrides` entry for the scope the delivery ran under
  already applied. A scope overrides a route's configuration and never
  its existence.
  """

  @typedoc """
  Where in the step one send sat: the deterministic fields
  `Statifier.Send.Processor` requires a processor to be idempotent on,
  read off the effect. Every field is the effect's own.
  """
  @type position :: %{
          send_id: String.t() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          c_index: non_neg_integer() | nil,
          owner: term()
        }

  @typedoc """
  The key `StatifierRouter.SendHandler` composes for one send
  (ADR-0005, decision 4): the scope half, where in the step the send sat,
  and the ordinal.

  The scope half is `execution_id` at the executor seam
  (`StatifierPersistence.Executor`'s context) and `session_id` on the
  send-processor shape (`Statifier.Send.Processor`'s `t:ctx/0`); it is
  the only part of the key that differs by host shape.

  `ordinal` is `nil` only for a send of a type the session did not
  register, which this handler never sees.
  """
  @type idempotency_key ::
          {scope :: String.t(), position :: position(), ordinal :: pos_integer() | nil}

  @typedoc "A registered route: the module serving it and that module's own configuration."
  @type t :: {module(), map()}

  @doc """
  Hands one built event off to this route's destination, at most once per
  `key`. Answers `:ok` when it was handed off and `{:error, reason}` when
  it was not.
  """
  @callback deliver(route_config :: map(), event :: Statifier.Event.t(), key :: idempotency_key()) ::
              :ok | {:error, term()}

  @doc """
  Whether `module` can serve as a route: loadable and exporting
  `deliver/3`. `StatifierRouter.Config` holds every registered adapter to
  this, as it holds a resolver to `StatifierRouter.Resolver.valid?/1`.

      iex> StatifierRouter.Route.valid?(StatifierRouter.Route)
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(module) when is_atom(module) and not is_nil(module) and not is_boolean(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :deliver, 3)

  def valid?(_other), do: false
end
