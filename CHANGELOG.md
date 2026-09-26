# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](https://github.com/riddler/statifier_router/blob/v0.6.0/changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.7.0] 2026-09-26

Feature release: a host that serves send types of its own can declare them, and the contract check says when it did not check a resolver's bindings. `StatifierRouter.Config.new/1` takes `:send_handlers`, merged with `:send_type` into the one `send_types:` snapshot every delivery carries, so `StatifierRouter.Contracts.check/3` stops reporting the host's own types as unsupported. Two fixes: `StatifierRouter.Migrations.up/1` refuses, before any DDL runs, a `:leading_columns` name that a table the call creates already declares, and `StatifierRouter.Broadway`'s partitioner keeps the producer up on a malformed `:bindings_resolver` answer.

Upgrading: **breaking for a host that sets `:bindings_resolver` and reads `StatifierRouter.Contracts.check/3`'s `:unchecked` entries** - the list now opens with `%{reason: :bindings_resolver, location: nil}`, the one entry with no location; a configuration without a resolver gets the report it got before. `Config.new/1`'s refusal union grows by one member, `{:exclusive_keys, :send_handlers, :send_types}`, answered only to a configuration that gives a non-empty `:send_handlers` beside a `:persistence_options` carrying its own `:send_types` and no `:send_type`. No migration, no new table, and no dependency floor moves.

### Added

- `StatifierRouter.Config.new/1` takes `:send_handlers`, a map from each send type the host serves itself to its processor module, merged with `:send_type` into the one `send_types:` snapshot every delivery carries, so `StatifierRouter.Contracts.check/3` no longer reports the host's own types under `:unsupported_types`; left out, the snapshot is built from `:send_type` alone as before.

### Changed

- **Breaking** for a host that sets `:bindings_resolver` and reads `StatifierRouter.Contracts.check/3`'s `:unchecked` entries: the list now opens with `%{reason: :bindings_resolver, location: nil}`, saying the bindings were not checked, where the report before was identical to a clean pass. It is the one entry with no location, so skip it or match its reason before reading `location`, and keep checking each scope's bindings with `StatifierRouter.Contracts.undeclared_binding_events/2`. This is the one change for a host with a resolver; a configuration without one gets the report it got before.

### Fixed

- `StatifierRouter.Migrations.up/1` raises `ArgumentError` naming the column and the tables before any DDL runs when a `:leading_columns` name is one a table the call creates already declares (`scope`, `inserted_at` and the like; the primary key the repo configures is not checked), where the migration before failed inside Postgres with a duplicate column error. A name only a table outside the call declares, such as `expires_at` under `up(from: 2)`, is accepted as before.
- `StatifierRouter.Broadway`'s partitioner no longer takes the producer down when a `:bindings_resolver` answers something that is not a list of bindings: it partitions that message by its message id, and `route/3` raises the `ArgumentError` in `handle_message/3`, where Broadway fails the message.

## [0.6.0] 2026-09-25

Feature release: a host that wraps the engine can plug into the router without forking it. `StatifierRouter.Config.new/1` takes `:on_create` and `:on_step`, which the default delivery calls in place of statifier_persistence's create and step; `:bindings_resolver`, which answers the bindings per scope through the new `StatifierRouter.BindingsResolver` behaviour; and `:execution_id`, which mints each new execution's id. `StatifierRouter.Migrations.up/1` takes the host column layout options `:leading_columns`, `:timestamps_position` and `:column_collations`. Every new key and option is optional, and a host that sets none of them sees no change.

Upgrading: `Config.new/1`'s refusal union grows by one member, `{:exclusive_keys, :bindings, :bindings_resolver}`, answered only to a configuration that gives both keys. No migration, no new table, and no dependency floor moves.

### Added

- `StatifierRouter.Config` takes `:on_create` and `:on_step`, a module or a fun the default delivery calls in place of `StatifierPersistence.Executions.create/4` and `step/5`, with the same arguments and return contract, inside the delivery's transaction; left out, the delivery calls statifier_persistence itself as before.
- `StatifierRouter.Config` takes `:bindings_resolver`, a module implementing the new `StatifierRouter.BindingsResolver` behaviour or an arity-1 fun, answering the bindings of one scope; `route/3`, the Broadway partitioner and `subscribe/3` read its answer for the scope in hand, checked for the reserved and duplicated binding ids as `:bindings` is. It is exclusive with `:bindings`, and `Config.new/1` refuses both with `{:error, {:exclusive_keys, :bindings, :bindings_resolver}}`; left out, `:bindings` is read as before.
- `StatifierRouter.Config` takes `:execution_id`, a module exporting `execution_id/3` or an arity-3 fun of `(scope, document, key)` answering a non-empty string, which the default delivery mints each new execution's id with; that id is the one on the address row, the created execution and the ledger. An answer that is not a non-empty string raises `ArgumentError`. Left out, the id is a UXID with the prefix `ex`, as before.
- `StatifierRouter.Migrations.up/1` takes `:leading_columns`, `:timestamps_position` and `:column_collations`, statifier_persistence's layout options under the same spellings and rules: host-owned columns immediately after `id`, `inserted_at` moved to follow them, and a collation per package text column, applied only as a version creates a table, on all four tables. `down/1` accepts and ignores them. Left out, the tables are built exactly as before.

## [0.5.0] 2026-09-25

Feature release: a live session's sends get a delivery scope and the execution target, and a delivery whose step selected no transition says so. `StatifierRouter.Config.new/1` takes `:processor_scope`, so a `Statifier.Session`'s sends resolve their routes under a scope's `:route_overrides`, and a fun there that answers neither a non-empty scope string nor `nil` is answered `{:error, {:invalid_value, :processor_scope, value}}`, a new member of the open `t:StatifierRouter.SendHandler.reason/0`. On the send-processor shape an immediate send to the reserved `execution` target is delivered or refused as at the executor seam, where it was answered as an unregistered route.

Upgrading: **two closed sets a host matches grow.** Every `:unregistered_routes` entry of `StatifierRouter.Contracts.check/3` now carries `reason`, `:unregistered` or `:no_timer_queue`, typed as the closed `t:StatifierRouter.Contracts.route_reason/0`; and `StatifierRouter.route/3` gains the outcome `{:dropped, binding_id, :unmatched_event}`, recorded on the routing ledger as `dropped: unmatched_event`, for a delivery whose step selected no transition. The dependency floors move to `statifier ~> 2.9` and `statifier_persistence ~> 0.18`; this package adds no migration and no new table.

### Added

- `StatifierRouter.Config.new/1` takes `:processor_scope`, a scope string or a zero-arity fun `StatifierRouter.SendHandler` calls per send, so a live `Statifier.Session`'s sends resolve their routes under that scope's `:route_overrides`.
- **Breaking** for a host that matches `StatifierRouter.route/3`'s outcomes exhaustively, or a custom `:delivery` module's answers: a binding's delivery whose step selected no transition for the event now answers `{:dropped, binding_id, :unmatched_event}` in place of `{:delivered, binding_id, execution_id}` or `{:created_and_delivered, binding_id, execution_id}`, and its routing-ledger row reads `dropped: unmatched_event` with the execution's id. The execution still took the event, so its input log holds it, and a created execution stays. The outcome cannot tell an event the current state has no transition for from one whose every guard was false. An execution-to-execution send keeps its outcomes. Add a clause for the new tuple wherever you match outcomes; no migration.

### Changed

- **Breaking** for a host that matches `StatifierRouter.Contracts.check/3`'s `:unregistered_routes` entries exactly or builds them itself: every entry now carries `reason`, `:unregistered` for a `<send>` whose literal `target` names no registered route (the entries it reported before), or `:no_timer_queue` for a `<send>` that writes a literal `delay` to a registered route on a configuration with no `:timer_queue`, a send `StatifierRouter.SendHandler` never queues and refuses at run time, as `{:no_timer_queue, send_id}` once the route resolves. A `%{route: _, location: _}` pattern still matches every entry. Add a `reason` key wherever you compare or build a whole entry, and treat a `:no_timer_queue` entry as you treat an unregistered route, or configure a `:timer_queue`. `StatifierRouter.Routes.unregistered/2` is unchanged.
- `t:StatifierRouter.Contracts.reason/0` and the new `t:StatifierRouter.Contracts.route_reason/0` are documented as closed sets: a new reason arrives only in a minor release that names it as breaking.
- On the send-processor shape, `StatifierRouter.SendHandler.perform/2` delivers an immediate `<send>` whose `target` is the reserved `execution` name to the execution its `document` and `key` params address, or refuses it as `{:error, {:send_refused, reason}}`, exactly as `handle_effect/3` does at the executor seam; it no longer answers `{:error, {:unregistered_route, "execution"}}`. The sender's scope is read from the address row its session id names, and a session id that names none is refused as `:unaddressed_sender`.
- Requires `statifier ~> 2.9` (the `last_selection` the outcome is read from) and `statifier_persistence ~> 0.18`. A host still on statifier_persistence below 0.17 runs that package's V08 migration before deploying, as its 0.17.0 changelog says.

## [0.4.1] 2026-09-23

Patch release: the publish-time contract check now flags a delayed send to the execution target. `StatifierRouter.Contracts.check/3` and `StatifierRouter.Contracts.undeclared_events/3` report such a `<send>` as a finding with reason `:delay`, the send `StatifierRouter.SendHandler` refuses at run time, so a host's publish step can catch it before a document goes live; `t:StatifierRouter.Contracts.reason/0` gains `:delay`. No migration, no new configuration option, and no dependency floor moves.

### Changed

- `StatifierRouter.Contracts.check/3` and `undeclared_events/3` report a
  delayed `<send>` to the execution target (one that writes `delay` or
  `delayexpr`) with a literal event and a literal `document` as a finding
  with reason `:delay`, without calling the lookup, because such a send
  is refused at run time; before, it passed whenever its receiver
  declared the event.

## [0.4.0] 2026-09-23

Feature release: a live session's delayed send, and the refusals and savepoints a host reads. `StatifierRouter.SendHandler.perform/2` now records a live session's delayed send on the host's `StatifierRouter.TimerQueue`, the same row the executor seam writes, and performs its cancel through that queue; a delayed send to the execution target is refused by name; and a delivery or a refusal row that fails settles at a savepoint of its own, so neither a host's own transaction around `StatifierRouter.route/3` nor a sender's step is lost to it.

Upgrading: **answers a host reads change.** A host that runs live sessions through `perform/2` and sends with a delay needs a `:timer_queue` in its configuration (without one the send is answered `{:error, {:no_timer_queue, send_id}}`), and that queue's `schedule/2` must add no second row for a key it already holds, because `perform/2` may be handed one send more than once. `{:delayed_send_unsupported, send_id}` is gone from `t:StatifierRouter.SendHandler.reason/0`. A delayed send to the execution target is answered `{:send_refused, :delay}` with a `delay` ledger row, where the executor seam answered `{:unregistered_route, "execution"}` with a `route` row. `perform/2` answers a cancel in a process holding no configuration with `{:no_config, StatifierRouter.SendHandler}`, where it answered `:ok`. At the executor seam a send to a route some scope overrides, with no delivery scope in reach, is refused as `{:no_delivery_scope, name}`. On the send-processor shape a cancel now reaches the configured queue's `cancel/3`, and that queue's `{:error, reason}` comes back from `perform/2`, where it answered `:ok` without calling the queue. Host queue code run at the executor seam is marked by `StatifierRouter.SendHandler.sending_execution/0`, so a `StatifierRouter.route/3` called from inside its `schedule/2` or `cancel/3` is refused with `{:reentrant_route, execution_id}`. An `:on_complete` route some scope overrides, reached with no delivery scope in the process (a delivery through `StatifierRouter.Delivery.deliver_event/4` that no `StatifierRouter.route/3` call encloses), answers `{:error, {:on_complete, name, {:no_delivery_scope, name}}}` and rolls that delivery back, where 0.3.0 used the route's registered configuration. No migration, no new configuration option, and no dependency floor moves.

### Changed

- `StatifierRouter.SendHandler.perform/2` records a delayed send on the configured `StatifierRouter.TimerQueue` under the same composed key and with the same row the executor seam writes, and performs a planned cancel through that queue's `cancel/3`; it no longer answers a delayed send with `{:error, {:delayed_send_unsupported, send_id}}`, and that reason is dropped from `t:StatifierRouter.SendHandler.reason/0`.
- `StatifierRouter.TimerQueue.schedule/2` now states that a queue holds at most one row per entry `key` (a repeat is answered `:ok` and adds no row), and the behaviour's moduledoc says how a host fires a queued row through `StatifierRouter.Config.route/3` and the route's `deliver/3`.
- `StatifierRouter.SendHandler.perform/2` answers a cancel with `{:error, {:no_config, StatifierRouter.SendHandler}}` when the calling process holds no configuration, where it answered `:ok`, and a delayed send the same way, where it answered `{:error, {:delayed_send_unsupported, send_id}}`. Install the configuration with `StatifierRouter.SendHandler.put_config/1` in the process `perform/2` runs in; the moduledoc says why this answer is not reported to the chart.
- A delayed send to the reserved `execution` target is answered `{:error, {:send_refused, :delay}}` by `StatifierRouter.SendHandler` on both host shapes, and recorded as a `send_refused` ledger row with the reason `delay` when the sender has an address row; at the executor seam it was answered `{:error, {:unregistered_route, "execution"}}` with a `route` row, which named a route no host could register. `t:StatifierRouter.SendHandler.refusal/0` gains `:delay`.
- `StatifierRouter.SendHandler.handle_effect/3` refuses a send or a delayed send to a route that some scope in `:route_overrides` overrides, when no delivery scope is in reach, with `{:error, {:no_delivery_scope, name}}` instead of sending it to the registered configuration. The send-processor shape (`perform/2`) is unchanged and still resolves such a send to the registered configuration. A route no scope overrides resolves as before on both shapes.
- `StatifierRouter.SendHandler.sending_execution/0` also names the sending execution while the timer queue's `schedule/2` and `cancel/3` run at the executor seam, so a `StatifierRouter.route/3` called from host queue code there is refused with `{:error, {:reentrant_route, execution_id}}`.
- `t:StatifierRouter.SendHandler.reason/0` gains `{:no_delivery_scope, name}`, the answer `handle_effect/3` gives a send to a route some scope overrides when no delivery scope is in reach.
- `StatifierRouter.SendHandler.perform/2` answers a delayed send with `{:error, {:no_timer_queue, send_id}}` when the configuration names no `:timer_queue`, and a delayed send to an unregistered route with `{:error, {:unregistered_route, name}}` and the same `send_refused` ledger row an undelayed send to it writes.
- `StatifierRouter.SendHandler.perform/2` answers a cancel with the timer queue's own `{:error, reason}` when its `cancel/3` fails, where it answered `:ok` without calling the queue.

### Fixed

- `StatifierRouter.route/3` called inside a host's own transaction no longer loses that transaction when a delivery answers `{:error, reason}`: the delivery rolls back to a savepoint of its own and the host's writes stand.
- An execution-to-execution send refused with a recorded reason no longer takes the sending step down when its `send_refused` ledger row cannot be written: the row rolls back to a savepoint of its own and the refusal is still reported.
- A sender's address read that fails while `StatifierRouter.SendHandler` records an unregistered-route or delayed-execution-send refusal no longer takes the sending step down: the read now sits inside the refusal row's savepoint, rolls back to it, and the refusal is still reported, with no ledger row.

## [0.3.0] 2026-09-22

Feature release: the receiver contract at publish. A host gets `StatifierRouter.Contracts`, pure functions its own publish step calls to find every execution-target `<send>` and every binding whose event the receiving document does not accept, judged through a lookup the host supplies, and `StatifierRouter.Contracts.check/3`, which runs every publish-time check this package ships and answers one report under five named keys. Which finding blocks a publish stays the host's decision.

Upgrading: one dependency floor moves, and no other: `statifier` to `~> 2.7`, the release carrying `Statifier.Chart.check_accepts/2`, which `StatifierRouter.Contracts` calls to judge a receiver that declares no events. No migration and no new configuration option.

### Added

- `StatifierRouter.Contracts.undeclared_events/3` lists every `<send>` to the
  reserved execution target whose literal event its receiving document does
  not accept, judged through a host-supplied lookup, with the sends an
  expression or a missing `event` or `document` left unchecked.
- `StatifierRouter.Contracts.undeclared_binding_events/2` lists every binding
  whose event its document does not accept, with the binding's id.
- `StatifierRouter.Contracts.check/3` runs every publish-time check the package
  ships - both `StatifierRouter.Routes` checks and the two above - and answers
  one report under five named keys.

### Changed

- The `statifier` requirement moves to `~> 2.7`, the release carrying
  `Statifier.Chart.check_accepts/2`, which judges a receiver that declares no
  events.

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
