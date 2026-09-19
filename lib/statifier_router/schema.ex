defmodule StatifierRouter.Schema do
  @moduledoc """
  The Ecto schemas over this package's three tables, one per table
  `StatifierRouter.Migrations.V01` creates:

    * `StatifierRouter.Schema.Address` - the address table (ADR-0002).
    * `StatifierRouter.Schema.Dedupe` - the dedupe table (ADR-0003).
    * `StatifierRouter.Schema.Ledger` - the routing ledger (ADR-0004).

  Each schema's compiled source is the table's name under the default
  table prefix, `"statifier_router_"`, with no Postgres schema. A host that
  configures another table prefix or a Postgres schema reaches its tables
  through `StatifierRouter.Config.put_meta/2` for a row it writes and
  `StatifierRouter.Config.queryable/2` for a query, which read the same
  configuration the migrations were given.
  """
end
