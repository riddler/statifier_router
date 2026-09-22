defmodule StatifierRouter.Schema.Subscription do
  @moduledoc """
  A row of the subscription table: one live source invocation, as
  `(execution_id, binding_id, invoke_id)`, carrying the `scope` and `key`
  the subscription reads events under (ADR-0007, section 6). Both are
  resolved once, at subscribe time, from the execution's own address row.

  The unique index on `(execution_id, binding_id, invoke_id)` is named in
  `StatifierRouter.Migrations.V02`; see `StatifierRouter.Schema` for how a
  row reaches a configured table.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          binding_id: String.t() | nil,
          execution_id: String.t() | nil,
          invoke_id: String.t() | nil,
          scope: String.t() | nil,
          key: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "statifier_router_subscriptions" do
    field(:binding_id, :string)
    field(:execution_id, :string)
    field(:invoke_id, :string)
    field(:scope, :string)
    field(:key, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
