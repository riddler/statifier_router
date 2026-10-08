defmodule StatifierRouter.WhereEventDataLandsTest do
  # Pins the "Where a source event's data lands" section of
  # docs/explanation/what-the-router-owns.md to the schemas: its table names
  # every column of every schema in StatifierRouter.Schema, and nothing else,
  # so a field added to a router schema fails here until the page names it.
  use ExUnit.Case, async: true

  @page Path.expand("../../docs/explanation/what-the-router-owns.md", __DIR__)
  @heading "## Where a source event's data lands"

  # Every Ecto schema module under StatifierRouter.Schema, read from the
  # application's module list, so a sixth schema is caught as a new field is.
  defp schemas do
    {:ok, modules} = :application.get_key(:statifier_router, :modules)

    Enum.filter(modules, fn module ->
      String.starts_with?(Atom.to_string(module), "Elixir.StatifierRouter.Schema.") and
        Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
    end)
  end

  defp schema_columns do
    for module <- schemas(),
        field <- module.__schema__(:fields),
        into: MapSet.new(),
        do: {module.__schema__(:source), Atom.to_string(module.__schema__(:field_source, field))}
  end

  defp page_columns do
    [_before, rest] = @page |> File.read!() |> String.split(@heading <> "\n", parts: 2)
    [section | _after] = String.split(rest, "\n## ", parts: 2)

    for [_row, table, column] <-
          Regex.scan(~r/^\| `(statifier_router_[a-z_]+)` \| `([a-z_]+)` \|/m, section),
        into: MapSet.new(),
        do: {table, column}
  end

  # sabotage: a field added to Schema.Ledger, the page row for the ledger
  # `reason` deleted, and a page row naming no column, each turned this red.
  test "the page names every column of every router schema, and no other" do
    from_schemas = schema_columns()
    from_page = page_columns()

    assert MapSet.size(from_schemas) > 0
    assert MapSet.difference(from_schemas, from_page) == MapSet.new(), "the page leaves out"
    assert MapSet.difference(from_page, from_schemas) == MapSet.new(), "the page names extra"
  end

  # sabotage: Schema.Location's table renamed turned this red.
  test "the router writes five tables, each through one schema" do
    tables = schemas() |> Enum.map(& &1.__schema__(:source)) |> Enum.sort()

    assert tables == [
             "statifier_router_addresses",
             "statifier_router_dedupe",
             "statifier_router_locations",
             "statifier_router_routing_ledger",
             "statifier_router_subscriptions"
           ]
  end
end
