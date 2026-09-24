defmodule StatifierRouter.PrivateIdTest do
  @moduledoc """
  No file the Hex package ships, and no file under `test/`, carries a
  private ruling, question or campaign id.

  Such an id is a number on a list of decisions, open questions or
  campaigns kept outside this repository, so a public reader cannot follow
  it. A comment states the substance instead: the record and section that
  decided it. The records under `docs/adr/` keep the ids they already carry
  as history and are not scanned; the package does not ship them.

  The shipped files are read from the `:files` of this project's own
  `package` config, so a path added there is scanned without editing this
  test.

  ## What it does not catch

    * A bare `R` or `Q` number with no ruling or question word beside it
      (see `@private_id`): so are an ADR's numbered sections and ordinary
      text this repository writes.
    * A campaign id in any shape other than the two-letter prefix and
      three digits below.
  """
  use ExUnit.Case, async: true

  # The shapes, each a separate alternative below:
  #
  # - a campaign id: `RF` or `SF`, three digits, an optional lower-case
  #   letter;
  # - a question id: `RQ-` and dash-separated alphanumeric parts;
  # - a ruling id qualified by a sub-number or a letter: `R`, digits, then
  #   `-`/`.` and digits, or one lower-case letter;
  # - a ruling id that is a bare letter: `R-` and one lower-case letter;
  # - a campaign decision id: `D`, digits, `-`, digits;
  # - a bare `R`/`Q` number, only where a word names it as one ("ruling",
  #   "question" or "Riddler" before it, or "ruling" after it).
  @private_id ~r/
    \b(?:RF|SF)\d{3}[a-z]?\b
    | \bRQ-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*
    | \bR\d+(?:[-.]\d+|[a-z])\b
    | \bR-[a-z]\b
    | \bD\d+-\d+\b
    | \b(?:[Rr]ulings?|[Qq]uestions?|Riddler)\s+[`*]*\K[RQ]\d+(?:[-.]\d+|[a-z])?\b
    | \b[RQ]\d+(?:[-.]\d+|[a-z])?(?=[`*]*,?\s+(?:operator\s+)?ruling\b)
  /x

  @root Path.expand("../..", __DIR__)

  defp private_ids(text), do: @private_id |> Regex.scan(text) |> Enum.map(&hd/1)

  defp expand(path) do
    full = Path.join(@root, path)

    if File.dir?(full),
      do: full |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1),
      else: [full]
  end

  defp scanned_files do
    shipped = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    (shipped ++ ["test"])
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Every invented id below is assembled from two halves at run time, so
  # this file's own source carries none of them and the scan of `test/`
  # below does not count them.
  defp invented(prefix, rest), do: prefix <> rest

  # sabotage: drop the campaign-id alternative from @private_id -> red on
  # the first two positives; restored, green (2026-09-23).
  test "the private-id pattern matches each id shape and no ordinary text" do
    positives = [
      {"as #{invented("RF", "999")} ruled", invented("RF", "999")},
      {"#{invented("RF", "999")}: the reason word", invented("RF", "999")},
      {"in #{invented("SF", "999")}b", invented("SF", "999b")},
      {"see #{invented("RQ-", "XX999-99")} for why", invented("RQ-", "XX999-99")},
      {"under ruling #{invented("R", "99-9")}, the", invented("R", "99-9")},
      {"under ruling #{invented("R", "99.9")}, the", invented("R", "99.9")},
      {"as #{invented("R", "99z")} has it", invented("R", "99z")},
      {"ruling #{invented("R-", "z")} said", invented("R-", "z")},
      {"decision `#{invented("D", "99-9")}` said", invented("D", "99-9")},
      {"open question #{invented("Q", "99")} asks", invented("Q", "99")},
      {"the #{invented("R", "96")} ruling of", invented("R", "96")}
    ]

    for {text, id} <- positives, do: assert(private_ids(text) == [id], text)

    negatives = [
      "ADR-0005, section 7",
      "RFC 7231 section 6",
      "released as v0.4.0",
      "### R1. What `src` is",
      "a question the router asks",
      "the ruling of 2026-08-29",
      "RT15, a corpus case id"
    ]

    for text <- negatives, do: assert(private_ids(text) == [], text)
  end

  # sabotage: put back main's send_handler.ex, whose comment above
  # @unregistered_route_reason opened with a campaign id -> red, naming the
  # file and the id; separately plant an invented campaign-shaped id in a
  # comment there -> red; each restored from a copy, green (2026-09-23).
  test "no shipped file and no test file carries a private ruling or campaign id" do
    found =
      for file <- scanned_files(),
          id <- file |> File.read!() |> private_ids(),
          do: "#{Path.relative_to(file, @root)}: #{id}"

    assert found == [],
           "private ruling or campaign ids - write the substance instead:\n" <>
             Enum.join(found, "\n")
  end
end
