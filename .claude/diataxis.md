---
# The docs manifest the documentation tools read. Generated from the family's manifest
# table: change a key there and regenerate. The two prose lines below may be sharpened.
product: statifier_router
family: statifier
audience: "Elixir developers whose events arrive from other systems, late or twice"
tone: "plain, second person, no marketing"
terminology:
  use:
    - execution
    - chart
    - document
    - revision
  avoid:
    - "run (noun)"
    - workflow instance
example_world: parcel-delivery
docs_root: docs
quadrants:
  tutorials: docs/tutorials
  how_to: docs/guides
  reference: docs/reference
  explanation: docs/explanation
readme: README.md
reference_generator: ex_doc
publish: hexdocs
contributor_paths:
  - docs/adr
  - docs/plans
  - docs/spikes
  - docs/research
  - docs/design
  - docs/measurements
  - CLAUDE.md
executed_snippets: []
readme_max_lines: 250
---

Delivers external events to the right durable execution: bindings, addressing, dedupe, per-key order.
Examples are written in parcel delivery: scans from several systems arrive late, twice or out of order.
