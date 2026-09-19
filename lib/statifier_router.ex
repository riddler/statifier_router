defmodule StatifierRouter do
  @moduledoc """
  Routes external events to durable statifier executions, creating them when
  absent.

  The front is Broadway: the host starts `StatifierRouter.Broadway` in its own
  supervision tree with any producer, and `partition_by` keeps every message
  for one key on one processor. Behind it sits a binding, addressing and
  delivery layer over `statifier_persistence`.

  ## What this package owns

    * Bindings: source -> match -> key -> document -> event, with `match` and
      `key` written as predicator programs over the normalized event.
    * The address table: `(scope, document, key)` -> `execution_id`.
    * Atomic get-or-create-and-deliver: the execution an address names is
      created when absent and handed the event in the same step.
    * Dedupe on `(binding, message_id)` with a horizon.
    * The recorded outcome vocabulary: every delivery attempt ends in one
      named outcome.

  ## What it does not own

    * Sinks and the route registry.
    * Execution-to-execution sends.
    * The source invoke.
    * Any queue adapter.
    * The webhook helper.
    * Timers: those are `statifier_oban`'s.
    * A publish store: a host callback resolves a document to its active
      chart.
    * Any process or supervisor: the host schedules the reapers and starts
      the pipeline.

  `scope` is an opaque host string; the package gives it no meaning.

  This release is the skeleton: of the pieces named above the binding is
  built, as `StatifierRouter.Binding`, and so are the tables behind the
  rest, created by `StatifierRouter.Migrations` and read through the
  schemas in `StatifierRouter.Schema`. Nothing writes those tables yet.
  Each piece lands behind the decision record that fixes it, in
  `docs/adr/`.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns this package's version, as `mix.exs` declares it.

      iex> is_binary(StatifierRouter.version())
      true
  """
  @spec version() :: String.t()
  def version, do: @version
end
