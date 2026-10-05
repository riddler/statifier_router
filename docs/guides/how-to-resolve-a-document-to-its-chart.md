# How to resolve a document to its chart

This guide tells the router which chart a new execution of a document starts
on, and which chart an existing execution is stepped against. It starts from
the charts you publish, either compiled at boot or kept in a publish store of
the host's own, and a configuration you are building.

This package keeps no publish store, so both answers are the host's. The
configuration takes two callbacks: `:resolver` for a new execution and
`:chart_resolver` for an existing one.

## Step 1. Answer the chart a new execution starts on

The host gives the router's configuration a `:resolver`: a module implementing
the `StatifierRouter.Resolver` behaviour, whose one callback takes
`(scope, document)` and answers `{content_hash, machine}` or
`{:error, reason}`. The router calls it only when it is about to create an
execution. A host with a publish store (a blocks document store, a database
table of published revisions) implements the callback over it:

```elixir
defmodule MyApp.PublishedCharts do
  @behaviour StatifierRouter.Resolver

  @impl StatifierRouter.Resolver
  def resolve(scope, document) do
    case MyApp.Publishing.active_revision(scope, document) do
      {:ok, revision} ->
        machine = MyApp.Publishing.compiled_chart(revision)
        {Statifier.Machine.identity(machine).content_hash, machine}

      :error ->
        {:error, :not_published}
    end
  end
end
```

A host whose charts are compiled at boot can use
`StatifierRouter.Resolver.Static` instead, over a map from
`{scope, document}` to a compiled machine:

```elixir
{:ok, machine} = Statifier.compile(File.read!("priv/charts/parcel_delivery.scxml"))

{:ok, resolver} =
  StatifierRouter.Resolver.Static.new(%{{"depot_north", "parcel_delivery"} => machine})
```

It answers the content hash of the machine's own identity, the hash
statifier_persistence records for the execution, and `{:error, :not_found}`
for a pair it does not hold. An arity-2 fun with the callback's signature is
accepted wherever a module is; `Static` returns one.

## Step 2. Check what an unresolved document does

When the resolver answers `{:error, reason}`, nothing is created: the
delivery's transaction rolls back, no row of this package's is written, and
`StatifierRouter.route/3` returns
`{:error, {:unresolved_document, document, reason}}`, which a front does not
acknowledge. Route one event for a document the resolver does not hold and
expect that error; an `{:ok, outcomes}` there means the resolver answered a
chart you did not mean to publish.

## Step 3. Answer the chart an existing execution started on

An execution that already exists keeps the chart it started on, and is never
resolved through the resolver. For those the configuration takes a second,
separate callback, `:chart_resolver`, from a content hash to
`{:ok, machine}` or `:error`: the chart the execution's record names. A host
with a publish store implements both over it; a host with charts compiled at
boot answers from the same machines it gave the static resolver. The second
event for a key is the one that reaches it, so route two events for one key to
check it.
