defmodule StatifierRouter.Schema.Dedupe do
  @moduledoc """
  A row of the dedupe table: one `(binding_id, message_id)` pair and the
  time it stops counting, `expires_at` (ADR-0003, section 6). A row whose
  `expires_at` has passed counts as absent even before it is removed.

  The unique index on `(binding_id, message_id)` is named in
  `StatifierRouter.Migrations.V01`; see `StatifierRouter.Schema` for how a
  row reaches a configured table.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          binding_id: String.t() | nil,
          message_id: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  schema "statifier_router_dedupe" do
    field(:binding_id, :string)
    field(:message_id, :string)
    field(:expires_at, :utc_datetime_usec)
  end
end
