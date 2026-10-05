# ADR-0009: A version tag push publishes to Hex through the release workflow, after three checks at the tagged commit

Status: proposed (2026-10-04) - moves the publish from a person's command
to a GitHub Actions workflow started by the tag push the tagging row
already allows; changes no function, module or package behaviour and no
`lib/` file; amends no earlier record

## Context

A release here has four steps. Three are already the automation's: the
version bump and the changelog promotion land as a release prep
(`.claude/wurk/release.md`), and once the prep is merged the session that
owns the release bead tags the merged commit and pushes the tag
(`CLAUDE.md`, the "tagging a release prep" row and the Release preps
paragraph). The fourth, `mix hex.publish`, has been run by hand from a
maintainer's machine, with the maintainer's own Hex credentials, after
the tag was pushed.

That leaves the step with the widest reach as the only one with no
written check in front of it. Nothing ties the published tarball to the
tagged commit, to the version `mix.exs` states there, to the default
branch, or to a green gate: the person running the command is the check.
Hex publishes from the working tree, so a publish from a dirty or wrong
checkout ships what that checkout holds.

Hex supports a publish without a logged-in user: `mix hex.publish` reads
the API key from the `HEX_API_KEY` environment variable in place of the
user's config, and `--yes` answers the confirmation prompt (`mix help
hex.publish`; `mix help hex.config`, the `api_key` entry).

## Decision

1. **The trigger is a version tag push, and nothing else.**
   `.github/workflows/release.yml` runs on the push of a tag matching
   `v*.*.*` (its `on:` key). It has no branch trigger, no pull-request
   trigger and no `workflow_dispatch`: there is no path to run it by hand
   on a tag of anyone's choosing. The tag push is the one the tagging row
   of `CLAUDE.md` already allows; this record adds no new tag rule.

2. **Three conditions at the tagged commit, checked in this order, and
   any one failing publishes nothing.**
   - The tagged commit is on the default branch: the branch name is read
     from the push event (`github.event.repository.default_branch`),
     never written into the file, that branch is fetched, and
     `git merge-base --is-ancestor` must answer yes (the steps "Fetch the
     default branch" and "Check the tagged commit is on the default
     branch").
   - The tag names the version: the tag name without its leading `v`
     must equal `@version` in `mix.exs` at the tagged commit (the step
     "Check the tag names the version in mix.exs").
   - The full quality gate is green at the tagged commit: the workflow
     provisions the toolchain and runs the `gate.full` command of
     `.claude/wurk.json` (`mix quality`) with the same steps `ci.yml`
     uses, copied rather than shared, against the same Postgres service
     and `PG*` environment `ci.yml`'s job declares (the step "Full
     quality gate"). It does not look up a CI result for the commit; it
     runs the gate itself.

   The first two run before the toolchain is installed, so a wrong tag
   stops in seconds. A fourth check sits beside them: when Hex already
   shows the version (`https://hex.pm/api/packages/statifier_router/releases/`
   answers 200 for it), the run stops and reports it, and any answer
   other than 200 or 404 stops it too (the step "Check Hex does not
   already show this version").

3. **The registry is Hex, and the key is the `HEX_API_KEY` secret.** The
   maintainers keep `HEX_API_KEY` as a GitHub Actions secret visible to
   this repository. The workflow reads it as `secrets.HEX_API_KEY` in the
   `env:` of the step "Publish to Hex" and nowhere else; that step runs
   `mix hex.publish --yes`. The workflow's own token is read-only
   (`permissions: contents: read`). No agent or session reads, prints or
   sets the key; creating, rotating and revoking it are the maintainers'.

4. **The docs publish with the package.** `mix hex.publish --yes` builds
   and publishes the docs as it does by default (`mix help hex.publish`,
   "Publishing documentation"), so HexDocs keeps one page per version.
   The docs that publish are the docs the gate's Docs stage has just
   built without a warning (`.quality.exs`, the `docs:` entry). Decided
   by the conductor under a standing consent, 2026-10-04.

5. **A failed run is never retried by the workflow.** A run that stops
   at a check or at the gate publishes nothing, and the tag stands where
   it was pushed as the record of what was attempted; a fix lands on the
   default branch and is released under the next version, and a pushed
   tag is never moved or pushed again. A run whose publish step failed on
   a registry or network error is re-run once, by hand, from the run's
   page in the Actions tab; a re-run of a gate that failed is never
   made, and a second failure of the publish step goes to the
   maintainers. A re-run of a run that did publish stops at the Hex
   check. The workflow carries no retry of its own. Decided by the
   conductor under a standing consent, 2026-10-04.

6. **A published version stands.** Hex lets a new version of an existing
   package be replaced or reverted only within one hour of its
   publication (`mix help hex.publish`, "Reverting a package" and
   `--replace`); after that hour the version stays on Hex and can only
   be retired (`mix help hex.retire`). No agent or session runs any of
   those commands.

7. **The authority table moves with it.** `CLAUDE.md`'s release row, the
   version-bump row's clause on the publish and its Release preps
   paragraph, and `.claude/wurk/release.md`, now say that an agent or a
   session never runs `mix hex.publish`, that the release workflow
   publishes on the tag push, and that a failed workflow is re-run from
   its Actions page, never worked round by a local publish. Ruled by the
   operator, 2026-10-04.

The shape of the workflow - it runs the gate itself, reads the default
branch from the push event, reads the version from `mix.exs` at the tag,
copies its toolchain steps from `ci.yml`, and has no manual dispatch - was
decided by the conductor under a standing consent, 2026-10-03.

## Consequences

- A publish needs nothing from a person's machine: pushing the tag the
  tagging row allows is the whole release step, and the run's page in
  the Actions tab is its log.
- What ships is what the tagged commit holds, checked against the default
  branch, the version and the gate. A tag pushed on a branch commit, a
  tag that disagrees with `mix.exs`, or a red gate publishes nothing.
- Every release runs the full gate once more, on top of the run `ci.yml`
  made when the commit reached the default branch: one gate's minutes per
  release. The job's timeout is 45 minutes, the CI job's 30 plus room
  for the checks and the publish.
- The toolchain, cache and gate steps, and the Postgres service with its
  `PG*` environment, exist twice, in `ci.yml` and in `release.yml`. A
  change to one is made to the other in the same change; nothing checks
  that they agree.
- The Postgres service is a job-level service, so it starts before the
  first check: a run a check stops still pays for the container's start.
- A Hex outage or a key the maintainers have revoked shows up as a red
  run with the tag already pushed. The re-run in decision 5 covers the
  first; the second is the maintainers' to fix before that re-run.
- A run that lands the package on Hex but fails on the docs leaves the
  version without docs, and a re-run stops at the Hex check. The docs
  are then the maintainers' to republish by hand.
- The third-party actions keep the floating major tags `ci.yml` uses
  (`actions/checkout@v4`, `erlef/setup-beam@v1`, `actions/cache@v4`), in
  a job that later holds the key; pinning them is a change to both files.
- The publish step runs this repository's `mix.exs` and the dependencies
  the cache step restored, with the key in its environment. The cache it
  restores was written by a run on the default branch or by an earlier
  run on the same tag, never by a pull request, whose caches stay on its
  own ref.
- The release row of `CLAUDE.md` still reads `never` for an agent: what
  changed is who presses the button, not what an agent may do.
- This record stays proposed until the workflow has published a version
  of this package.
