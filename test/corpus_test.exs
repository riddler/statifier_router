defmodule StatifierRouter.CorpusTest do
  @moduledoc """
  Runs every case under `corpus/cases/` through `StatifierRouter.CorpusRunner`
  against the real delivery, and checks that the corpus keeps the rules
  `corpus/README.md` sets for it: every case is language-neutral JSON named
  for its id, no timer carries a `<send>` with a `target`, and every
  `target` a chart does write names a route the corpus registers, or the
  reserved execution target, rather than a host scheme.

  Each case runs in its own SQL sandbox: the runner routes, fires timers
  and reads back from the test's one process, so every write is ordered by
  that process and the sandbox hides nothing a case compares.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.CorpusRunner
  alias StatifierRouter.SendHandler
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
      # The publish cases: publish-undeclared-receiver-event's
      # undeclared_events emptied -> that case red; publish-undeclared-
      # binding-event's undeclared_binding_events emptied -> that case red;
      # the runner's lookup made to answer {:ok, []}, and separately
      # {:error, :not_published}, for a document the declarations leave
      # out -> publish-computed-set-fallback red each time, so it holds
      # only through the computed vocabulary; each restored, green.
      test "#{Path.basename(path, ".json")} holds what it expects" do
        kase = CorpusRunner.load!(@path)
        assert CorpusRunner.run(kase) == kase["expected"]
      end
    end
  end

  describe "the corpus" do
    test "carries the cases corpus/README.md lists" do
      ids = Enum.map(CorpusRunner.case_paths(), &Path.basename(&1, ".json"))

      assert ids == [
               "click-then-impression",
               "click-then-orphan-timeout",
               "grace-click-after-expiry",
               "impression-then-click",
               "impression-then-expiry",
               "publish-computed-set-fallback",
               "publish-undeclared-binding-event",
               "publish-undeclared-receiver-event",
               "reaped-address-drop",
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

    # sabotage: `target="joined_records"` changed to a host scheme
    # `target="sqs://joined"` in charts/impression_click_join.scxml -> red
    # naming that send; restored, green.
    test "writes a target only on a routed send, and only a registered route name" do
      routes = CorpusRunner.route_names()
      assert routes != []

      for path <- CorpusRunner.chart_paths(),
          [tag] <- Regex.scan(~r/<send\s[^>]*>/, File.read!(path)) do
        assert_send_tag(path, tag, routes)
      end
    end

    # The execution target is reserved (ADR-0006, section 1): a send that
    # writes it names another execution rather than a route, and no case
    # can register it, because `StatifierRouter.Config.new/1` refuses a
    # route adapter under it. It is the one target a chart may write that
    # no case registers; every other unregistered name still fails.
    # sabotage: the exemption widened to accept any target -> this test
    # red on the depot_audit send; restored, green.
    test "exempts the reserved execution target and no other unregistered name" do
      routes = CorpusRunner.route_names()
      execution = SendHandler.execution_target()
      refute execution in routes

      send =
        ~s(<send type="#{CorpusRunner.send_type()}" target="#{execution}" event="parcel.returned">)

      assert_send_tag("parcel", send, routes)

      unregistered =
        ~s(<send type="#{CorpusRunner.send_type()}" target="depot_audit" event="parcel.returned">)

      refute "depot_audit" in routes

      assert_raise ExUnit.AssertionError, ~r/names no route the corpus registers/, fn ->
        assert_send_tag("parcel", unregistered, routes)
      end
    end

    # sabotage: the script guard in CorpusRunner.run/1's publish clause
    # removed -> this test red, the case answering its contracts with the
    # step ignored; restored, green.
    test "fails a publish case that carries a script" do
      kase =
        CorpusRunner.case_paths()
        |> Enum.find(&(Path.basename(&1, ".json") == "publish-computed-set-fallback"))
        |> CorpusRunner.load!()
        |> Map.put("script", [%{"advance" => "PT1H"}])

      assert_raise ArgumentError, ~r/runs no script and carries one/, fn ->
        CorpusRunner.run(kase)
      end
    end

    # sabotage: `expects_sends!/1` in CorpusRunner made to return `:ok`
    # unconditionally -> this test red, the eight cases still green, which
    # is the point: a case losing its `sends` member is otherwise silent;
    # restored, green.
    test "fails a case that registers routes and states no expected sends" do
      kase =
        CorpusRunner.case_paths()
        |> hd()
        |> CorpusRunner.load!()
        |> update_in(["expected"], &Map.delete(&1, "sends"))

      assert kase["routes"] != []

      assert_raise ArgumentError, ~r/states no expected sends/, fn ->
        CorpusRunner.run(kase)
      end
    end
  end

  # One `<send>` tag of a chart: a timer carries no target; any other send
  # carries the host's send type and a target that is a route some case
  # registers, or the reserved execution target.
  defp assert_send_tag(path, tag, routes) do
    if tag =~ ~r/\sdelay=/ do
      refute tag =~ ~r/\starget=/, "#{path}: the timer #{tag} carries a target"
    else
      assert [[_, type]] = Regex.scan(~r/\stype="([^"]*)"/, tag),
             "#{path}: the send #{tag} carries no type"

      assert type == CorpusRunner.send_type(),
             "#{path}: the send #{tag} is not the host's send type"

      assert [[_, target]] = Regex.scan(~r/\starget="([^"]*)"/, tag),
             "#{path}: the send #{tag} carries no target"

      assert target == SendHandler.execution_target() or target in routes,
             "#{path}: the send #{tag} names no route the corpus registers"
    end
  end

  # Every key and string value in a decoded JSON document.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)

  defp strings(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | strings(value)] end)

  defp strings(_scalar), do: []
end
