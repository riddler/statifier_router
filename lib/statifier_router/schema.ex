defmodule StatifierRouter.Schema do
  @moduledoc """
  The Ecto schemas over this package's five tables, one per table
  `StatifierRouter.Migrations.V01`, `StatifierRouter.Migrations.V02` and
  `StatifierRouter.Migrations.V04` create:

    * `StatifierRouter.Schema.Address` - the address table (ADR-0002).
    * `StatifierRouter.Schema.Dedupe` - the dedupe table (ADR-0003).
    * `StatifierRouter.Schema.Ledger` - the routing ledger (ADR-0004).
    * `StatifierRouter.Schema.Subscription` - the subscription table
      (ADR-0007), which `StatifierRouter.Migrations.V02` creates.
    * `StatifierRouter.Schema.Location` - the location table (ADR-0002,
      the Amendment of 2026-09-30), which `StatifierRouter.Migrations.V04`
      creates and the package reads and writes only on a configuration
      that sets `:basichttp`.

  Each schema's compiled source is the table's name under the default
  table prefix, `"statifier_router_"`, with no Postgres schema. A host that
  configures another table prefix or a Postgres schema reaches its tables
  through `StatifierRouter.Config.put_meta/2` for a row it writes and
  `StatifierRouter.Config.queryable/2` for a query, which read the same
  configuration the migrations were given.

  Each schema's `id` is a `StatifierRouter.Schema.Id`: the database fills
  it in on insert and the schema reads it back as the column holds it, an
  integer under the repo's default `bigserial` key, a string under a text
  key the `:primary_key` option of `StatifierRouter.Migrations` built.
  """
end
