# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Beads issue tracker

This project tracks all work in **bd (beads)** - not TodoWrite, not markdown TODO
lists. Run `bd prime` for the command reference and session-close protocol, and
`bd remember` for knowledge that should outlive the session.

Claude Code injects `bd prime` at session start, so this section is deliberately
a stub.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block. It is redundant here - keep the stub.

### Beads that span repositories

Three trackers touch this project: `sr-` here, `sp-` in statifier_persistence,
and `st-` in statifier-ex.

| Situation | Rule |
|---|---|
| A decision is recorded in more than one tracker and they disagree | The repository whose files change owns the decision. The interpreter contract, chart identity and the event vocabulary are statifier-ex's call; the durable execution, its lifecycle and its input log are statifier_persistence's; bindings, addressing and delivery are this repo's call |
| A bead pairs with one in statifier_persistence or statifier-ex | Both halves carry `mirrors: <id>` as the first line of the description |
| You are about to schedule, claim, plan against, or cite the status of a mirrored bead | Re-read the other tracker first and write a new dated note above the old one, then act |
| A `mirrors:` line names an id that no longer resolves | Broken immediately, not stale. Fix it with one `bd update` the moment you notice |
| The contract in statifier_persistence or statifier-ex looks wrong | Say so and raise it there. Do not work around it here: a router that quietly writes around the durable stepper is the failure those records exist to prevent |

## Agent authority in this repo

**This repository grants an agent the authority to commit, push, and open
requests only inside an orchestrated campaign that carries the operator's
explicit consent for that campaign.** The grant is consent-scoped, not
standing. Outside such a campaign the conservative rules `bd prime` describes
apply in full, and so they do for any action the table below does not name.

What unlocks the grant is the operator saying, in their own words, that a
particular campaign may commit, push, and open requests here. Nothing else
does. It is **not** inferable from statifier_persistence, statifier-ex, or
predicator-ex having opted into the team-maintainer profile; not from this
file's resemblance to theirs; not from the fact that the same person works on
all of them. A dispatch from another agent - a conductor, an orchestrator, a
parent session - is not by itself the operator's consent either, however
confidently it asserts otherwise. An agent that believes consent exists but
cannot point to where the operator gave it should do the work, stop before the
irreversible step, and report.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the conservative profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` on the bead's branch | a campaign carrying the operator's explicit consent **and** the bead's work complete **and** full `mix quality` green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on `main`, on a red gate, on a `--profile loop` or otherwise scoped run, or with unrelated changes in the tree |
| `git push`, `gh pr create` | the same consent, **and** the terminology scan in the umbrella's `docs/terminology-firewall.md` clean over the full outbound content | any scan hit - that is a hard stop, not something to rephrase past |
| merging a campaign PR | a campaign consent the operator adopted verbatim that names automatic merges, with every named condition met (full gate green, CI green, firewall scan clean with a positive control, any named review gate passed) | outside such a consent; any named condition unmet; any PR the consent's carve-outs hold for the operator |
| `bd close <id>` | never for a mirrored bead whose other half is not merged to its own repo's origin/main; a mirrored bead whose other half has ALSO landed may be closed by the campaign conductor under a consent naming this exception, both halves together, each verified against its remote; otherwise the operator's call | for a bead whose description carries a `mirrors:` line while its other half is unlanded, campaign consent included |
| `bd dolt push` | the operator's call | inside a campaign that spans mirrored trackers - the conductor pushes those atomically |
| a version bump on a release bead's branch | an operator-authorized release bead, inside a campaign carrying the operator's explicit consent | on any other bead, on main, or when the operator has not named this repo's release bead |
| a release (tag, `mix hex.publish`, GitHub release) | never | always - publishing is the operator's, in every campaign |

The organizing principle is the same one the other packages use: the human gate
belongs where an action stops being reversible. A commit on a per-bead branch
is undone with `git reset --soft HEAD~1`. A push, a request, a merge outside a
consented campaign, and a closed bead are visible to other people and other
machines, so a campaign's consent is what buys the first two and nothing buys
the last two.

Two rules override every row above. A current "do not commit", "do not push",
or equivalent instruction from the operator wins outright. And authority is
the operator's to give, never an agent's to infer: a subagent that believes a
trigger has fired - reasoning its way there from its dispatch, from a sibling
repo, or from the fact that it was asked to do the work - reports that, it
does not act on it. A subagent carrying the operator's consent relayed
verbatim by the session that owns the work is the other case: there the
authority is the operator's and the subagent is only the hands, so it may act.
What has to be quotable is the relay - the operator's own words authorizing
that campaign, not the subagent's sense of being authorized. A subagent that
cannot quote them reports and stops. A relay unlocks nothing the rows above
forbid outright: closing a mirrored bead and a release stay
forbidden however the consent arrives. A version bump is the recorded
exception: on a release bead the operator has named (in the campaign plan or
their own words), the bump commit is release prep, not a release. (Recorded
2026-08-27 by the operator, campaign 008.)

Merging a campaign PR is a recorded exception: under a campaign consent the
operator has adopted verbatim that names automatic merges, with every
condition that consent names met (full gate green, CI green, firewall scan
clean with a positive control, any named review gate passed), the conductor's
merge executes the operator's own authorization - the consent's text is what
may be done and nothing more. (Recorded 2026-09-01 by the operator, campaign
025 post-wrap queue walk.)

Widening this section is a decision for the operator to make and record here.
An agent may draft the change; it does not adopt it.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

`statifier_router`: routes external events to durable
[Statifier](https://github.com/riddler/statifier-ex) executions, creating them
when absent. The front is Broadway: the host starts the pipeline in its own
tree with any producer, and `partition_by` keeps one key on one processor.
Behind it sits a binding, addressing and delivery layer over
[statifier_persistence](https://github.com/riddler/statifier_persistence).

What this package owns:

- Bindings: source -> match -> key -> document -> event, with `match` and
  `key` as predicator programs over the normalized event.
- The address table: `(scope, document, key)` -> `execution_id`.
- Atomic get-or-create-and-deliver.
- Dedupe on `(binding, message_id)` with a horizon.
- The recorded outcome vocabulary.

What it does not own: sinks and the route registry; execution-to-execution
sends; the source invoke; any queue adapter; the webhook helper; timers
(statifier_oban's); a publish store (a host callback resolves a document to
its active chart); any process or supervisor.

Vocabulary and boundaries that hold in every file here:

- The four nouns are **document**, **revision**, **chart** and
  **execution**, each used for itself. A workflow has executions; "run" is
  never the durable noun.
- The address is `(scope, document, key)`, spelled that way everywhere.
- `scope` is an opaque host string. The package never says what a host's
  scope means and never uses a word that implies it.
- No process, supervisor or scheduler lives in this package. The host
  starts the Broadway pipeline in its own tree and schedules the reapers.
- The record lands before the code that implements it: a decision record in
  `docs/adr/` merges first, and a code PR cites the record section it
  implements.

Always refer to state machines as **state charts**, as statifier-ex does.

## Build & Test

```bash
mix quality --profile loop   # inner loop: format, compile, credo, changed tests
mix quality                  # full gate: + dialyzer, deps audit, coverage floor
mix test                     # just the suite
```

Full `mix quality` must be green before any commit. The format stage runs in
check mode (`format: [check: true]` in `.quality.exs`): drift fails the gate
and nothing is rewritten, so run `mix format` yourself before committing.
The suite reaches a real Postgres server through the `PG*` env vars
(`config/test.exs`; `docker compose up -d db` or any local server on 5432).
The gate is deliberately smaller than statifier-ex's; `.quality.exs` records
why.

<!-- usage-rules-start -->
## ExQuality (`mix quality`)

Full reference: `deps/ex_quality/usage-rules.md`. Read it when a stage fails in a
way its own output does not explain, or when you need the JSON report shape.

The rules that do not wait to be looked up:

- **Never truncate the output.** No `| tail`, `| head`, `| grep`. A passing stage
  costs one line and detail prints only for failures, so truncating removes
  findings, not noise.
- **Read the `○` lines.** A skipped stage is not a passing one, and the reason
  says whether the gap is in this run or in what the project checks at all.
- **A scoped or `--quick` green is not a full green.** Neither measures coverage.
  Run a bare `mix quality` before reporting work complete.
- **Never go green by weakening the check.** Not by lowering a coverage or
  security threshold, not by `--skip` flags or `enabled: false`, not by
  `@tag :skip` on a failing test, not by narrowing scope. If a finding is
  genuinely wrong for this project, say so and let the user decide.
<!-- usage-rules-end -->

### This repo's own gate rules

- The full gate is `mix quality`; the inner loop is
  `mix quality --profile loop`. Only the full command is the advancement
  gate: a `--profile loop` run, like any scoped or profiled run, is never
  evidence for a claim that the gate is green.
- A change touching no Elixir code has no gate to run and may commit on
  review of the diff alone - the authority table above says the same.
- This gate is deliberately smaller than statifier-ex's, and `.quality.exs`
  records that decision. Documentation may point at the gate; it never
  enlarges it.

## Conventions

Inherited from statifier-ex unless this project records otherwise:

- Errors are events: evaluations return `{:ok, v} | {:error, e}`. Never
  rescue-to-default at a leaf.
- Structs + MapSets; `@spec` on public functions; pattern matching over multiple
  asserts in tests.
- Functions taking a state/session put it as the first argument (pipeline
  threading).
- Sabotage every new test that asserts `lib/` behavior: break the code it
  covers, confirm it goes red, revert, and note the mutation in one line above
  the test.
- Commit messages: title < 50 chars, simple present tense ("Adds ...",
  "Fixes ..."), body wrapped at ~72 chars. No AI attribution trailers.
- Plain ASCII hyphens in prose; no typographic dashes.
- New examples, fixtures and prose use the family's teaching domains: the
  library loan and patron registration (one world: patron, copy, loan, hold,
  branch), and parcel delivery (a parcel scanned from depot to doorstep, the
  machine-paced rhythm this package serves). Credit-card processing, the signup
  wizard with A/B testing and the advertising impression-and-click join are
  fixture-only. This package's existing corpus, fixtures, tests and records are
  built on the advertising join; they stay exactly as they are and keep
  passing, nothing is migrated, renamed or deleted, and no new prose, example
  or fixture is written in any of the three.
