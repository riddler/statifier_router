defmodule StatifierRouter.Schema.Ledger do
  @moduledoc """
  A row of the routing ledger: one recorded outcome of one routing attempt
  for one binding (ADR-0004, section 4). The ledger is append-only.

  `key` is empty for key_refused, `execution_id` is empty where the
  outcome names no execution, and `reason` is empty for every outcome but
  key_refused, when it holds the reason term as `inspect/1` renders it
  (see `StatifierRouter`). See `StatifierRouter.Schema` for how a row
  reaches a configured table.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          binding_id: String.t() | nil,
          message_id: String.t() | nil,
          scope: String.t() | nil,
          outcome: String.t() | nil,
          key: String.t() | nil,
          execution_id: String.t() | nil,
          reason: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "statifier_router_routing_ledger" do
    field(:binding_id, :string)
    field(:message_id, :string)
    field(:scope, :string)
    field(:outcome, :string)
    field(:key, :string)
    field(:execution_id, :string)
    field(:reason, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
