defmodule StatifierRouter.Schema.Address do
  @moduledoc """
  A row of the address table: `(scope, document, key)` -> `execution_id`
  (ADR-0002, section 1). `terminal_seen_at` is empty until this package
  first sees the execution terminal (ADR-0002, section 5).

  The unique index on `(scope, document, key)` is named in
  `StatifierRouter.Migrations.V01`; see `StatifierRouter.Schema` for how a
  row reaches a configured table.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          scope: String.t() | nil,
          document: String.t() | nil,
          key: String.t() | nil,
          execution_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          terminal_seen_at: DateTime.t() | nil
        }

  schema "statifier_router_addresses" do
    field(:scope, :string)
    field(:document, :string)
    field(:key, :string)
    field(:execution_id, :string)
    field(:terminal_seen_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
