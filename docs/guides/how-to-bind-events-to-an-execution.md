# How to bind events from several sources to one execution

This guide makes every event about one parcel, whichever system sent it, land
on that parcel's one durable execution. It starts from a configuration the
router can deliver with (`StatifierRouter.Config.new/1` answering
`{:ok, config}`) and a `parcel_delivery` document whose chart takes the
events you bind.

A binding reads source -> match -> key -> document -> event: the source the
event came from, a [predicator](https://github.com/riddler/predicator-ex)
`match` program that says whether this binding takes it, a `key` program that
names the parcel, the document whose execution the key addresses, and the
chart event it is delivered as. The address is `(scope, document, key)`.
`StatifierRouter.Binding` documents every field and its default.

## Step 1. Write one binding per source, all naming one document and one key

A depot scan opens an execution of the `parcel_delivery` document; the
carrier's delivery report for the same parcel lands on that same execution.
Two bindings, one document, one key:

```elixir
[
  %{id: "depot_scans_to_parcel", source: "depot_scanners",
    match: ~s(event.kind == "scan"), key: "event.parcel_id",
    document: "parcel_delivery", event: "parcel.scanned"},
  %{id: "carrier_scans_to_parcel", source: "parcel_scans",
    match: ~s(event.kind == "delivered"), key: "event.parcel_id",
    document: "parcel_delivery", event: "parcel.delivered"}
]
```

Pass the list as the configuration's `:bindings`. A binding the router
cannot build is refused there: `StatifierRouter.Config.new/1` answers
`{:error, {:binding, index, reason}}` with its position in the list, and a
duplicated binding `id` answers `{:error, {:duplicate_binding_id, id}}`.

## Step 2. Normalize the key in the key program

The `key` program's answer is the key exactly as it is answered: the router
trims nothing and converts nothing, and it refuses any answer that is not a
non-empty string (ADR-0001, section 3). When the sources of one document send
the same id in different shapes, that is two hazards:

- **A number is refused.** A depot scanner that sends `"parcel_id": 1042771`
  has every one of its events refused on that binding: one `key_refused` row
  in the routing ledger per event, and nothing delivered.
- **A padded string is a second address.** A carrier webhook that sends
  `" 1042771 "` addresses `(scope, "parcel_delivery", " 1042771 ")`, not the
  parcel's execution: under the default `create: :if_absent` its first event
  opens a second execution for the same parcel, and under `create: :never` it
  is dropped as `:no_execution`.

The key program is where the author normalizes, and it goes on **every**
binding that addresses the document: a cast to `string` and a `trim` make one
key of both shapes, and a binding left with the raw path keys its own events
apart again.

```elixir
[
  %{id: "depot_scans_to_parcel", source: "depot_scanners",
    match: ~s(event.kind == "scan"), key: "trim(event.parcel_id::string)",
    document: "parcel_delivery", event: "parcel.scanned"},
  %{id: "carrier_scans_to_parcel", source: "parcel_scans",
    match: ~s(event.kind == "delivered"), key: "trim(event.parcel_id::string)",
    document: "parcel_delivery", event: "parcel.delivered"}
]
```

Both bindings answer `"1042771"` for `1042771` and for `" 1042771 "`, so both
sources reach one execution, and the Broadway partitioner, which evaluates the
same program, keeps them on one processor. An event that carries no
`parcel_id` is still refused: `trim` answers an error for an absent value.
`StatifierRouter.Binding`'s module documentation runs this key program as a
doctest.

Check it by routing one event from each source for the same parcel: the
first answers `{:created_and_delivered, binding_id, execution_id}` and the
second `{:delivered, binding_id, execution_id}` with the same execution id.
A second execution id means the two keys still differ.

## Step 3. Give each scope its own bindings, when scopes differ

`:bindings` is one list for every scope. A host whose scopes each route their
own sources to their own documents gives the configuration a
`:bindings_resolver` instead: a module implementing the
`StatifierRouter.BindingsResolver` behaviour, whose one callback takes the
event's scope and answers the `%StatifierRouter.Binding{}` structs that scope
routes by, or an arity-1 fun with that signature.

```elixir
defmodule MyApp.DepotBindings do
  @behaviour StatifierRouter.BindingsResolver

  @impl StatifierRouter.BindingsResolver
  def resolve(scope) do
    # The host's own rows, each built once with StatifierRouter.Binding.new/1
    # and cached; the router keeps no answer between calls.
    MyApp.Routing.cached_bindings(scope)
  end
end

{:ok, config} =
  StatifierRouter.Config.new(
    repo: MyApp.Repo,
    store: store,
    executor: MyApp.Executor,
    resolver: MyApp.PublishedCharts,
    chart_resolver: &MyApp.PublishedCharts.chart/1,
    bindings_resolver: MyApp.DepotBindings
  )
```

The two keys are exclusive: a configuration that gives both is refused with
`{:error, {:exclusive_keys, :bindings, :bindings_resolver}}`. The router asks
the resolver once per `StatifierRouter.route/3` call, with the event's scope,
and checks each answer as it checks the static list: a duplicated binding `id`
or the reserved one makes `route/3` return `{:error, reason}` before any
binding is evaluated. The Broadway partitioner asks it too, and
`StatifierRouter.subscribe/3` asks it for the scope of the subscribing
execution's address row.

The publish-time checks take no scope, so a host checks each scope's bindings
with `StatifierRouter.Contracts.undeclared_binding_events/2`, and hands
`StatifierRouter.Addresses.reap/3` the bindings of every scope it routes.
`StatifierRouter.Contracts.check/3` never calls the resolver: its
`:undeclared_binding_events` is empty, and its `:unchecked` list opens with
`%{reason: :bindings_resolver, location: nil}`, the one entry with no
location, saying the bindings were not checked. Without a
`:bindings_resolver`, `:bindings` is read exactly as before, and `check/3`'s
report carries no such entry.
