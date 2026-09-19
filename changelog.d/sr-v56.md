### Added

- `StatifierRouter.Delivery`, the default delivery module: for a binding whose `create` is `:if_absent`, it gets or creates the execution an address names and steps the event into it in one transaction on the host's repo, and returns `{:created_and_delivered, binding_id, execution_id}`, `{:delivered, binding_id, execution_id}` or `{:dropped, binding_id, :finished}`.
- `StatifierRouter.Config.new/1` takes `:store`, `:executor`, `:resolver` and `:chart_resolver`, the four options `StatifierRouter.Delivery` requires.
