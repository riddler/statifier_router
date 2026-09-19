# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.1.0] 2026-09-19

Feature release, and the first: the Broadway front and the binding, addressing and delivery layer that routes external events to durable statifier executions, creating them when absent. A host gets bindings over predicator programs, the `(scope, document, key)` address table, get-or-create-and-deliver in one transaction under three create modes, dedupe with a horizon, the recorded outcome vocabulary, a resolver behaviour for the chart a new execution starts on, and two reapers it schedules itself.

### Added

- `StatifierRouter.Binding`: `new/1` validates a binding and compiles its `match` and `key` programs once, `match/2` and `key/2` evaluate them over a normalized event, and `project/2` builds the delivered event's data from the binding's field paths.
- `StatifierRouter.Migrations`: `up/1` and `down/1` create and drop the address table, the dedupe table and the routing ledger from a host's one-line delegating migration, with `from:`, `version:`, `table_prefix:` and `prefix:` options.
- `StatifierRouter.Config`: `new/1` resolves the host's repo, table prefix and Postgres schema, and `table/2`, `put_meta/2` and `queryable/2` point the `StatifierRouter.Schema` modules at the configured tables.
- `StatifierRouter.Schema.Address`, `StatifierRouter.Schema.Dedupe` and `StatifierRouter.Schema.Ledger`: Ecto schemas over the three tables.
- `StatifierRouter.route/3` routes one event through the configured bindings and returns one outcome per enabled binding for the event's source, in configuration order, writing a routing ledger row for each key_refused and reporting each no_match as the telemetry event `[:statifier_router, :route, :no_match]`.
- `StatifierRouter.Config.new/1` takes `:bindings`, built through `StatifierRouter.Binding.new/1` with a duplicate binding id refused, and an optional `:delivery` module that `route/3` hands each delivery to, defaulting to `StatifierRouter.Delivery`.
- `StatifierRouter.Delivery`, the default delivery module: for a binding whose `create` is `:if_absent`, it gets or creates the execution an address names and steps the event into it in one transaction on the host's repo, and returns `{:created_and_delivered, binding_id, execution_id}`, `{:delivered, binding_id, execution_id}` or `{:dropped, binding_id, :finished}`.
- `StatifierRouter.Config.new/1` takes `:store`, `:executor`, `:resolver` and `:chart_resolver`, the four options `StatifierRouter.Delivery` requires.
- `StatifierRouter.Broadway`, the Broadway front: a pipeline the host starts in its own supervision tree with any producer, which hands each message to `StatifierRouter.route/3`, partitions each message by the address of the first enabled `order: :by_key` binding for its source whose `match` holds and whose `key` resolves, or by its message id when no such binding addresses it, and fails rather than acknowledges a message whose routing returns an error or raises.
- `StatifierRouter.Dedupe.claim/4`, called first in every `StatifierRouter.Delivery` transaction: a message a binding already handled within its dedupe horizon is `{:duplicate, binding_id}`, recorded on the ledger and delivered nowhere; an expired dedupe row counts as absent.
- `StatifierRouter.Dedupe.reap/2`, a plain function the host schedules, deletes expired dedupe rows and returns `{:ok, count}`.
- `StatifierRouter.route/3` returns `{:error, :no_message_id}` for an event whose `message_id` is `nil` or empty, before any binding is evaluated.
- `StatifierRouter.Addresses.reap/2`, a plain function the host schedules, stamps address rows whose execution it first sees finished and deletes those whose longest enabled binding horizon has elapsed; one call examines at most `:limit` rows and returns a `next` cursor.
- `StatifierRouter.Delivery` delivers for `:never` bindings, returning `{:dropped, binding_id, :no_execution}` when the address has no row, and for `:always_new` bindings, creating one execution per delivery with no address row.
- `StatifierRouter.Resolver`, the behaviour a host implements to name the chart a new execution of a document starts on; `StatifierRouter.Config.new/1` accepts as `:resolver` a module implementing it or an arity-2 fun.
- `StatifierRouter.Resolver.Static.new/1`, a resolver over a map from `{scope, document}` to a compiled machine, for tests and for charts compiled at boot.
- `StatifierRouter.route/3` returns `{:error, {:unresolved_document, document, reason}}` when the resolver answers `{:error, reason}` for a document: the delivery's transaction rolls back, so nothing is created and no row is written.
