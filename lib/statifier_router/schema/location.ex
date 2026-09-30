defmodule StatifierRouter.Schema.Location do
  @moduledoc """
  A row of the location table: the BasicHTTP location token of the
  execution one address row names (ADR-0002, the Amendment of 2026-09-30,
  decision 1).

  `address_id` references the address row's `id` and is deleted with it;
  `token` is the path segment a location ends in. Both carry a unique
  index, named in `StatifierRouter.Migrations.V04`. The package reads and
  writes this table only on a configuration that sets `:basichttp`
  (`StatifierRouter.BasicHTTP`).
  """

  use Ecto.Schema

  @primary_key {:id, StatifierRouter.Schema.Id, autogenerate: true}

  @type t :: %__MODULE__{
          id: StatifierRouter.Schema.Id.t() | nil,
          address_id: StatifierRouter.Schema.Id.t() | nil,
          token: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "statifier_router_locations" do
    field(:address_id, StatifierRouter.Schema.Id)
    field(:token, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
