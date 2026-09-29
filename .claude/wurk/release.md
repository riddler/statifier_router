# Statifier_router extension: /wurk:release

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others. The shape
was copied from statifier_persistence's own `.claude/wurk/release.md`; the
reference for every shape below is **the most recent release-prep commit on
`main`**, found with:

```bash
git log --oneline --no-patch -L '/@version/,+1:mix.exs'
```

Where this file and that commit disagree, the commit is the evidence and this
file is the defect. This file names no SHA and no version on purpose: either
goes stale at the next release.

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
unreleased work lives one file per issue in `changelog.d/`, and the fragments
are assembled into a version section at release. So `release.changelog` is
deliberately absent, and the promotion this repo performs is step B below - a
required step, not an optional one.

If `changelog.d/` holds no fragment other than its own `README.md`, there is
nothing to release, and the run stops exactly as it would on an empty
unreleased section.

## Step A: the version carrier

**None.** `mix.exs`'s `@version` is the only place this package's version
string lives; `lib/` reads it from `mix.exs` at compile time
(`StatifierRouter.version/0`), and `mix.exs` derives
`source_ref: "v#{@version}"` from the same attribute. The skill's own
`version_file` edit is the whole of the bump. If a carrier is ever added, it
belongs in this section and in the table below, in the same change that adds
it.

## Step B: promote the changelog fragments

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   below the header (above the previous version's section): the bracketed
   version, a single space, then the date, **with no `-` separator between
   them**, matching statifier_persistence's changelog. The
   date is the LOCAL date of the machine cutting the prep, the one `date +%F`
   prints there at the moment you write the heading.
3. Write a short lead paragraph between the heading and the first `### `
   sub-heading, saying what the release is ("Feature release: ...", "Patch
   release: ...") and what a user gets. A breaking change is called out in
   bold.
4. Under the lead, write the fragments' bullets grouped by heading and ordered
   `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. **Carry
   every bullet over byte for byte.**
5. **No link reference.** The bracketed versions in the headings are
   deliberately unlinked.
6. Delete the promoted fragment files in the same commit. `README.md` stays.
7. **Move the header's `changelog.d/` link to the version being cut.** The
   paragraph at the top of `CHANGELOG.md` links `changelog.d/README.md` by
   absolute GitHub URL at a release tag,
   `https://github.com/riddler/statifier_router/blob/vX.Y.Z/changelog.d/README.md`,
   not at `main`: `changelog.d/` is not a published file (it is in neither
   `package()`'s `files:` nor `docs()`'s `extras:` in `mix.exs`), and the
   family's HexDocs standard links an unpublished file at the release tag
   whenever the file exists there, falling back to `blob/main` only when it
   does not. `changelog.d/README.md` survives every release (step 6), so it
   exists at every tag, and the link always names a tag. Rewrite the `vX.Y.Z`
   in that URL to the version this prep cuts, in every release - major, minor
   and patch alike. The tag does not exist yet while the prep is open; it is
   created at the merged prep commit, before the published docs are built
   from it. This is the one edit step B makes in `CHANGELOG.md` outside the
   new section, and nothing else moves the link: left alone, it drifts one
   release behind at each prep, which is how it came to name v0.7.0 after
   0.8.0 had shipped.

## The README install pin

`release.readme_pin` is `true`. `README.md`'s `def deps` snippet carries
`{:statifier_router, "~> X.Y.0"}` - the exact-minor form, with the patch
component written as a literal `0`. The pre-1.0 banner at the top of
`README.md` recommends pinning to an exact minor, and the snippet
demonstrates the same thing. A patch release leaves the pin alone; only a
major or minor release moves it.

```bash
grep 'statifier_router, "~>' README.md   # the pin, in the ~> X.Y.0 form
grep '@version "' mix.exs                # the version it should track
```

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step B |
| `changelog.d/*.md` (deleted) | step B |

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. `CLAUDE.md`'s authority table allows a version bump only on
the branch of a release bead the operator has named (in the campaign plan or
their own words) - the family norm, not a grant a campaign consent has to
name - and the bump plus step B is release *prep*, nothing more. What follows
the prep is split by that table's tagging and release rows and its "Release
preps" paragraph. Once the prep is merged to `origin/main`, the conductor or the session that owns the release bead tags
that merged commit with the new version and pushes the tag; a tag before the
bump is on `origin/main`, or naming any other version or commit, is not
allowed. Publishing - `mix hex.publish`, a GitHub release, a docs republish
included - is the operator's one release step, trigger **never**, in every
campaign, and no consent or relay delegates it. `changelog.d/README.md` ends
its "At release" paragraph with "and tag it": that is the tag the conductor
or the release bead's session makes on the merged prep, and it never extends
to the publish.
