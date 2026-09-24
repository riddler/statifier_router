# Quality configuration for statifier_router.
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, full test suite with coverage,
#                                 then the isolated tests in a run of their
#                                 own. Run before every commit.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
# Agents: prefer `--format json --report -` when you want to route on results.
#
# Copied from statifier_persistence's gate, and deliberately smaller than
# statifier-ex's. That repo's custom stages - the gate guard, the ADR guard
# and judge, the regression ratchet - exist to protect a conformance corpus
# and an accepted ADR set this package does not have yet. Adopting any of
# them here is a decision to record when there is something for it to
# protect, not a default to inherit.
#
# There is deliberately no .credo.exs either: credo's own defaults under
# --strict are the gate until this package has a reason to deviate from one.

[
  compile: [
    warnings_as_errors: true
  ],

  # Check-mode, not reformat-mode (the family-wide decision the statifier
  # repos share): a gate that rewrites drifting files cannot report drift as
  # a finding, so unformatted code would pass instead of going red. Drift
  # fails the stage; run `mix format` yourself before committing.
  format: [
    check: true
  ],

  credo: [
    strict: true
  ],

  # The published docs are part of the package, so the gate checks them the
  # way HexDocs and hex.pm will read them. The Docs stage runs `mix docs` and
  # fails on any ExDoc warning. The Doc links stage fails on the link rules
  # ExDoc accepts silently: a README relative link to a file not in the
  # package files, a published relative link to a file that is not an extra,
  # two extras sharing a basename, and a silent rewrite to a different extra.
  # That is how two relative links into docs/adr/ and changelog.d/ shipped in
  # 0.1.0, rendered as links to the README itself with `mix docs` clean.
  # `:auto` runs both whenever ex_doc is installed, which it is in dev and
  # test.
  docs: [enabled: :auto],
  doc_links: [enabled: :auto],

  # The second test step. The modules tagged :isolated take real Postgres
  # locks outside the SQL sandbox by switching the one shared repo to
  # :auto, which is repo-wide; beside the async suite that deadlocks
  # tests they do not contain. test_helper.exs excludes the tag from the
  # Tests stage, and this stage runs only it, in an OS process of its own.
  #
  # Not a second configuration of the Tests stage: it is a different
  # slice of the suite, which that stage has no way to express next to
  # the default one. `--only` with no tagged module fails the stage
  # rather than passing on nothing.
  #
  # Coverage is still measured over the whole suite, against the same
  # floor in coveralls.json: this stage exports its cover data
  # (`--export-coverage`, into cover/, which .gitignore already ignores)
  # through the json report type, which writes a file and applies no floor
  # to the slice, and the Tests stage's `mix coveralls` imports it (the
  # `coveralls` alias in mix.exs adds `--import-cover cover`) before its
  # own floor is checked. The live migration tests are the only
  # tests of the migration modules, so without the import the floor would
  # measure them at zero.
  #
  # kind: :writer is for ordering, not for the build. Writers run one at a
  # time before the parallel analysis phase, so this finishes - and its
  # cover data is on disk - before the Tests stage starts; as a reader it
  # would run beside that stage against the same database, which is the
  # interleaving the split exists to rule out.
  custom: [
    [
      key: :isolated,
      name: "Isolated tests",
      command: "mix",
      args: ["coveralls.json", "--only", "isolated", "--export-coverage", "isolated"],
      env: [{"MIX_ENV", "test"}],
      parse: :none,
      kind: :writer
    ]
  ],

  # No Tests stage args. The stage hands the same args to `mix coveralls`
  # on the full gate and to plain `mix test` on `--quick` and on a
  # `--test-scope` run, and `mix test` refuses excoveralls' `--import-cover`
  # as an unknown option, so the import is the `coveralls` alias in mix.exs
  # instead: it reaches only the command that measures coverage.

  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
