# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](https://github.com/riddler/statifier_router/blob/main/changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.2.0] 2026-09-22

Feature release: the outbound half, the execution target and the source invoke. A chart now reaches the world through named routes a host registers and overrides per scope, addresses another durable execution by document and key through the same one transaction a binding's delivery uses, and holds an `<invoke>` open as a subscription to a binding. A host gets the `StatifierRouter.Route` and `StatifierRouter.TimerQueue` behaviours, `StatifierRouter.SendHandler` for both shapes a registered send type arrives in, `StatifierRouter.Webhook` as a Plug-shaped front, `StatifierRouter.Routes` for a publish-time check of the routes a machine sends to, and `StatifierRouter.PinSource` so an addressed execution holds its chart back from retirement.

Upgrading: run V02 against an existing database. A host already running V01 writes `StatifierRouter.Migrations.up(from: 2)` - `from:` is inclusive, so that call runs V02 and nothing before it - and V02 adds the subscription table without re-running V01's `CREATE TABLE`. `StatifierRouter.Config.new/1` takes six new options, each optional and each defaulting to the 0.1.0 behaviour: `:route_adapters` (the route registry - it is spelled `:route_adapters`, and `:routes` is a statifier_persistence snapshot option carried inside `:persistence_options`), `:route_overrides`, `:send_type`, `:timer_queue`, `:on_complete` and `:persistence_options`. Two dependency floors move, and no other: `statifier` to `~> 2.6` and `statifier_persistence` to `~> 0.13`, the releases carrying host-registered Event I/O Processor send types.

### Added

- `StatifierRouter.Route`, the behaviour a host implements for one named, one-way outbound destination a chart reaches with `<send target="...">`.
- `StatifierRouter.SendHandler`, which serves both shapes a registered send type reaches a host in: `Statifier.Send.Processor` for a live session, and `handle_effect/3` for a process-less host to call from its `StatifierPersistence.Executor`.
- `StatifierRouter.TimerQueue`, the behaviour a host implements for the durable queue a delayed route send is recorded on, keyed by `{scope, send_id}`.
- `StatifierRouter.Config` takes `:route_adapters`, `:route_overrides`, `:send_type` and `:timer_queue`, and `StatifierRouter.Config.route/3` resolves a route name in a scope.
- Giving `:send_type` puts the `Statifier.Send.Types` snapshot for that type into `:persistence_options`, so every create and every step of every delivery declares the host's processor to the engine.
- A `<send>` whose `target` is the reserved name `execution` delivers to the durable execution at the sender's scope, its `document` param and its `key` param, through the same transaction, dedupe and ledger a binding's delivery uses.
- `StatifierRouter.Delivery.deliver_event/4` delivers one prebuilt event under a delivery plan, the door an execution-to-execution send comes in by.
- `StatifierRouter.Addresses.by_execution/2` answers the address row naming one execution, or `nil`.
- `StatifierRouter.SendHandler.execution_target/0` answers the reserved target name.
- A `<send>` whose `target` names no registered route writes one `send_refused` routing-ledger row, under the reserved binding id `execution` and the reason `route`, beside the `{:error, {:unregistered_route, name}}` the sender already heard; a send whose key's scope half names no address row has no scope to record and is reported without a row, and a ledger insert that fails rolls back to its own savepoint rather than to the sending step's.
- `StatifierRouter.subscribe/3` and `StatifierRouter.cancel/2` subscribe one execution's `<invoke>` to a binding for the lifetime of the invoking state, and undo it (ADR-0007).
- `StatifierRouter.SourceInvoke` maps an invoke's start and the engine's cancellation onto those two calls, for a host's invoke handler to delegate to.
- `StatifierRouter.Migrations.V02` adds the subscription table those calls write. A host already running V01 migrates to it with `StatifierRouter.Migrations.up(from: 2)`, since `from:` names the first version the host has not run and the walk includes it.
- `StatifierRouter.Schema.Subscription`: the Ecto schema over the subscription table.
- `StatifierRouter.Routes.unregistered/2` lists every `<send>` of the
  configuration's send type whose literal `target` names no registered route,
  with the sends an expression left unchecked, for a host's own publish step.
- `StatifierRouter.Routes.unsupported_types/2` lists every `<send>` whose
  literal `type` is outside the set the configuration registers.
- `StatifierRouter.Config`'s `:on_complete` names a registered route an execution's donedata is handed to on the delivery that finishes it, as a `done.execution` event under an idempotency key with no ordinal.
- `StatifierRouter.PinSource`, a `StatifierPersistence.PinSource` over the
  address table: a chart is not retired while an address row names one of
  its active executions.
- `StatifierRouter.Webhook.handle/3` routes one verified webhook request,
  taking the message id from the provider's event id or, absent one, the
  lowercase hex SHA-256 of the raw body.
- `StatifierRouter.Webhook.status/1` answers the HTTP status a provider
  should see for one `handle/3` answer: `200` for a recorded outcome, `500`
  for an error.
- `StatifierRouter.Config`'s `:persistence_options` carries the
  statifier_persistence snapshot options - `:routes`, `:invoke_types` and
  `:send_types` - onto every create and every step of every delivery.

### Changed

- `StatifierRouter.Delivery.deliver/4` answers `{:error, {:reentrant_route, execution_id}}` when a route called at the executor seam calls back into the sending execution, instead of opening a nested step.
- `StatifierRouter.Config.new/1` refuses a route registered under the reserved name with `{:reserved_route, name}`, and a binding whose `id` is that name with `{:reserved_binding_id, name}`.
- `StatifierRouter.Config.new/1` refuses a `:store` whose adapter options
  name a repo other than the configuration's own.
- `StatifierRouter.Addresses.reap/2` deletes an address row whose execution
  the store no longer holds instead of refusing with
  `{:error, :execution_not_found}`, so one such row no longer ends every
  sweep that reaches it.
- `StatifierRouter.Broadway.start_link/1` raises `ArgumentError` when `:name` is
  missing or is not an atom, as its options table has always said it would; it
  previously started an unnamed pipeline instead, and passed a
  `{:via, module, term}` name through to Broadway, which accepts one. Give the
  pipeline an atom name, and register it under a registry, if it needs one, by
  that atom rather than by passing the `{:via, module, term}` tuple as `:name`.
- The `statifier` floor is `~> 2.6` and the `statifier_persistence` floor is `~> 0.13`, the releases carrying host-registered Event I/O Processor send types.

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
