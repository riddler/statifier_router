defmodule StatifierRouter.CorpusTest do
  @moduledoc """
  Runs every case under `corpus/cases/` through `StatifierRouter.CorpusRunner`
  against the real delivery, and checks that the corpus keeps the rules
  `corpus/README.md` sets for it: every case is language-neutral JSON named
  for its id, and no chart carries a `<send>` with a `target`.

  Each case runs in its own SQL sandbox: the runner routes, fires timers
  and reads back from the test's one process, so every write is ordered by
  that process and the sandbox hides nothing a case compares.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.CorpusRunner
  alias StatifierRouter.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)
  end

  describe "every case" do
    for path <- CorpusRunner.case_paths() do
      @external_resource path
      @path path

      # sabotage: redelivered-impression's second ledger row expected
      # "delivered" in place of "duplicate" -> that case red, the other five
      # green; restored, green. Second mutation: Delivery.duplicate/4
      # recorded "delivered" -> redelivered-impression red; restored, green.
      # Third mutation: `<cancel sendid="orphan"/>` deleted from
      # charts/impression_click_join.scxml -> click-then-impression red, the
      # uncancelled orphan timer still pending in its expected timers;
      # restored, green. That catch depends on click-then-impression's last
      # advance keeping the clock STRICTLY under the orphan send's 1 hour
      # deadline: the runner's fire_due/3 compares with `!= :gt`, so a send
      # due exactly at the boundary fires and the case goes green again with
      # the cancel gone. Any case rewrite must keep that advance sub-1h.
      test "#{Path.basename(path, ".json")} holds what it expects" do
        kase = CorpusRunner.load!(@path)
        assert CorpusRunner.run(kase) == kase["expected"]
      end
    end
  end

  describe "the corpus" do
    test "carries the six cases corpus/README.md lists" do
      ids = Enum.map(CorpusRunner.case_paths(), &Path.basename(&1, ".json"))

      assert ids == [
               "click-then-impression",
               "click-then-orphan-timeout",
               "impression-then-click",
               "impression-then-expiry",
               "redelivered-impression",
               "two-clicks-for-one-impression"
             ]

      readme = File.read!(Path.join(CorpusRunner.corpus(), "README.md"))
      for id <- ids, do: assert(readme =~ "| `#{id}` |")
    end

    test "names every case for its id" do
      for path <- CorpusRunner.case_paths() do
        assert CorpusRunner.load!(path)["id"] == Path.basename(path, ".json")
      end
    end

    # sabotage: a string value ":impression" in one case -> red naming it;
    # removed, green.
    test "holds no term of a programming language in any case" do
      for path <- CorpusRunner.case_paths() do
        bytes = File.read!(path)
        refute bytes =~ "%{", "#{path} carries a map literal"
        refute bytes =~ "Elixir.", "#{path} carries a module name"

        for string <- strings(JSON.decode!(bytes)) do
          refute string =~ ~r/^\s*:[A-Za-z_]/, "#{path} carries the atom-like string #{string}"
        end
      end
    end

    test "sends to no target from any chart" do
      for path <- CorpusRunner.chart_paths() do
        refute File.read!(path) =~ ~r/<send\s[^>]*target/, "#{path} sends to a target"
      end
    end
  end

  # Every key and string value in a decoded JSON document.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)

  defp strings(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | strings(value)] end)

  defp strings(_scalar), do: []
end
