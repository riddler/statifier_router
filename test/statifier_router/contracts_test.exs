defmodule StatifierRouter.ContractsTest do
  use ExUnit.Case, async: true

  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Contracts
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.Routes
  alias StatifierRouter.TestRepo

  doctest StatifierRouter.Contracts

  @type_string "depot:router"

  # The receiving document: a parcel scanned from depot to doorstep.
  @parcel """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
    <state id="at_depot">
      <transition event="parcel.scanned" target="in_transit"/>
    </state>
    <state id="in_transit">
      <transition event="parcel.delivered" target="delivered"/>
    </state>
    <final id="delivered"/>
  </scxml>
  """

  defp config(opts \\ []) do
    {:ok, config} =
      [
        repo: TestRepo,
        delivery: MyApp.Delivery,
        send_type: @type_string,
        route_adapters: %{"doorstep_photos" => {RecordingRoute, %{}}}
      ]
      |> Keyword.merge(opts)
      |> Config.new()

    config
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  # The courier's round for one day, with the given `<send>` elements in
  # its one state's onentry. The first send starts on line 4.
  defp courier_round(sends) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_round">
      <state id="on_round">
        <onentry>
    #{sends}
        </onentry>
      </state>
    </scxml>
    """
  end

  defp to_parcel(event) do
    """
    <send type="#{@type_string}" target="execution" event="#{event}">
      <param name="document" expr="'parcel'"/>
      <param name="key" expr="parcel_id"/>
    </send>
    """
  end

  # A send to the parcel written with `delay` or `delayexpr` (the given
  # attribute), its event attribute and its params as given.
  defp delayed(delay_attr, event_attr, params) do
    """
    <send type="#{@type_string}" target="execution" #{event_attr} #{delay_attr}>#{params}</send>
    """
  end

  @parcel_params ~s(<param name="document" expr="'parcel'"/><param name="key" expr="parcel_id"/>)

  # A lookup a delayed send must never reach.
  defp never_asked, do: fn document -> flunk("the lookup was asked for #{document}") end

  defp declared(names), do: fn "parcel" -> {:ok, names} end
  defp undeclared, do: fn "parcel" -> {:ok, :undeclared, compile!(@parcel)} end
  defp unpublished, do: fn _document -> {:error, :not_published} end
  defp declares_both, do: declared(["parcel.scanned", "parcel.delivered"])

  defp binding(id, event, document \\ "parcel") do
    {:ok, binding} =
      Binding.new(
        id: id,
        source: "depot_feed",
        match: "event.kind == '#{id}'",
        key: "event.parcel_id",
        document: document,
        event: event
      )

    binding
  end

  describe "undeclared_events/3 under a declaration" do
    # Sabotage: answering nil for every `{:ok, names}` in judge/3 (dropping
    # the `event in names` test) empties `undeclared` and this goes red.
    test "refuses an undeclared literal event with its <send> location" do
      machine = compile!(courier_round(to_parcel("parcel.scanned") <> to_parcel("parcel.lost")))

      assert %{undeclared: [finding], unchecked: []} =
               Contracts.undeclared_events(config(), machine, declares_both())

      assert %{event: "parcel.lost", document: "parcel", reason: :undeclared} = finding
      assert %Statifier.Parser.Location{start_line: 8} = finding.location
    end

    # Sabotage: replacing `event in names` in judge/3 with a prefix match
    # (a descriptor-like relation) accepts `parcel.scanned` under the
    # declared `parcel` and this goes red.
    test "a declared entry is a name, compared by equality" do
      machine = compile!(courier_round(to_parcel("parcel.scanned")))

      assert %{undeclared: [%{event: "parcel.scanned", reason: :undeclared}]} =
               Contracts.undeclared_events(config(), machine, declared(["parcel"]))
    end

    # Sabotage: treating `{:ok, []}` as "no declaration" passes the send
    # and this goes red.
    test "an empty declaration accepts nothing" do
      machine = compile!(courier_round(to_parcel("parcel.scanned")))

      assert %{undeclared: [%{reason: :undeclared}]} =
               Contracts.undeclared_events(config(), machine, declared([]))
    end

    # Sabotage: dropping the Enum.reverse in undeclared_events/3 puts
    # `parcel.returned` before `parcel.lost`.
    test "reports findings in document order" do
      machine = compile!(courier_round(to_parcel("parcel.lost") <> to_parcel("parcel.returned")))

      assert %{undeclared: [%{event: "parcel.lost"}, %{event: "parcel.returned"}]} =
               Contracts.undeclared_events(config(), machine, declares_both())
    end
  end

  describe "undeclared_events/3 when the receiver declares nothing" do
    # Sabotage: answering :undeclared instead of :undeclared_by_computed_set
    # in judge/3's `{:ok, :undeclared, machine}` arm turns this red.
    test "judges by the computed set and the reason says so" do
      machine = compile!(courier_round(to_parcel("parcel.delivered") <> to_parcel("parcel.lost")))

      assert %{undeclared: [finding], unchecked: []} =
               Contracts.undeclared_events(config(), machine, undeclared())

      assert %{event: "parcel.lost", document: "parcel", reason: :undeclared_by_computed_set} =
               finding
    end

    # Sabotage: comparing the event with Statifier.Chart.events/1's strings
    # by equality instead of calling check_accepts/2 refuses `parcel.lost`
    # under the `parcel.*` descriptor and this goes red.
    test "uses the engine's descriptor matching, not string equality" do
      wildcard = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
        <state id="at_depot"><transition event="parcel.*" target="done"/></state>
        <final id="done"/>
      </scxml>
      """

      lookup = fn "parcel" -> {:ok, :undeclared, compile!(wildcard)} end
      machine = compile!(courier_round(to_parcel("parcel.lost")))

      assert %{undeclared: [], unchecked: []} =
               Contracts.undeclared_events(config(), machine, lookup)
    end
  end

  describe "undeclared_events/3 for an unpublished receiver" do
    # Sabotage: answering :undeclared for `{:error, :not_published}` in
    # judge/3 turns this red.
    test "is a finding of its own" do
      machine = compile!(courier_round(to_parcel("parcel.scanned")))

      assert %{
               undeclared: [
                 %{event: "parcel.scanned", document: "parcel", reason: :not_published}
               ],
               unchecked: []
             } = Contracts.undeclared_events(config(), machine, unpublished())
    end

    # Sabotage: dropping judge/3's catch-all arm lets a CaseClauseError out
    # instead of the ArgumentError that names the answer.
    test "raises on a lookup answer outside the three" do
      machine = compile!(courier_round(to_parcel("parcel.scanned")))

      assert_raise ArgumentError, ~r/the lookup answered :nope for "parcel"/, fn ->
        Contracts.undeclared_events(config(), machine, fn _document -> :nope end)
      end
    end
  end

  describe "undeclared_events/3 reports what it cannot judge" do
    # Sabotage: answering a guessed literal for a `{:compiled, _, _}` event
    # in literal_event/1 makes the send a finding and this goes red.
    test "an eventexpr is unchecked, never passed" do
      send = """
      <send type="#{@type_string}" target="execution" eventexpr="outcome">
        <param name="document" expr="'parcel'"/>
      </send>
      """

      assert %{undeclared: [], unchecked: [%{reason: :eventexpr, location: location}]} =
               Contracts.undeclared_events(config(), compile!(courier_round(send)), unpublished())

      assert %Statifier.Parser.Location{start_line: 4} = location
    end

    # Sabotage: answering :eventexpr from literal_event/1's last clause
    # turns this red.
    test "a send with no event is unchecked as :no_event" do
      send = """
      <send type="#{@type_string}" target="execution">
        <param name="document" expr="'parcel'"/>
      </send>
      """

      assert %{undeclared: [], unchecked: [%{reason: :no_event}]} =
               Contracts.undeclared_events(config(), compile!(courier_round(send)), unpublished())
    end

    # Sabotage: matching a leading lit (`[["lit", value] | _]`) instead of
    # exactly one in literal_param/1 reads `'par' + 'cel'` as a receiver
    # and this goes red.
    test "a document that is not one lit of a non-empty string is unchecked, never passed" do
      variants = [
        ~s(<param name="document" expr="receiver"/>),
        ~s(<param name="document" expr="'par' + 'cel'"/>),
        ~s(<param name="document" expr="''"/>),
        ~s(<param name="document" location="receiver"/>),
        ~s(<param name="document" expr="'parcel'"/><param name="document" expr="'parcel'"/>)
      ]

      for params <- variants do
        send = """
        <send type="#{@type_string}" target="execution" event="parcel.lost">#{params}</send>
        """

        assert %{undeclared: [], unchecked: [%{reason: :document_expr}]} =
                 Contracts.undeclared_events(
                   config(),
                   compile!(courier_round(send)),
                   unpublished()
                 ),
               params
      end
    end

    # Sabotage: reading only `params` (dropping the namelist half of
    # literal_document/1) reports this :no_document instead.
    test "a namelist entry named document is unchecked as :document_expr" do
      send = """
      <send type="#{@type_string}" target="execution" event="parcel.lost" namelist="document"/>
      """

      assert %{undeclared: [], unchecked: [%{reason: :document_expr}]} =
               Contracts.undeclared_events(config(), compile!(courier_round(send)), unpublished())
    end

    # Sabotage: answering :document_expr for `{[], []}` in
    # literal_document/1 turns this red.
    test "a send with no document is unchecked as :no_document" do
      send = """
      <send type="#{@type_string}" target="execution" event="parcel.lost">
        <param name="key" expr="parcel_id"/>
      </send>
      """

      assert %{undeclared: [], unchecked: [%{reason: :no_document}]} =
               Contracts.undeclared_events(config(), compile!(courier_round(send)), unpublished())
    end

    # Sabotage: swapping the two `with` clauses in judge_send/3 (the
    # document read before the event) reports the document's reason and
    # this goes red.
    test "when both the event and the document are uncheckable, the event's reason is reported" do
      variants = [
        {~s(eventexpr="outcome"), ~s(<param name="key" expr="parcel_id"/>), :eventexpr},
        {~s(eventexpr="outcome"), ~s(<param name="document" expr="receiver"/>), :eventexpr},
        {"", ~s(<param name="key" expr="parcel_id"/>), :no_event},
        {"", ~s(<param name="document" expr="receiver"/>), :no_event}
      ]

      for {event_attr, params, reason} <- variants do
        send = """
        <send type="#{@type_string}" target="execution" #{event_attr}>#{params}</send>
        """

        assert %{undeclared: [], unchecked: [%{reason: ^reason}]} =
                 Contracts.undeclared_events(
                   config(),
                   compile!(courier_round(send)),
                   never_asked()
                 ),
               send
      end
    end
  end

  describe "undeclared_events/3 for a delayed send (ADR-0008, the 2026-09-23 Amendment)" do
    # Sabotage: dropping delivery_reason/4's `delay != nil` clause judges
    # the send by the lookup, which flunks, and this goes red.
    test "a literal delay with a literal event and document is a :delay finding, lookup unasked" do
      machine =
        compile!(
          courier_round(delayed(~s(delay="2h"), ~s(event="parcel.delivered"), @parcel_params))
        )

      assert %{undeclared: [finding], unchecked: []} =
               Contracts.undeclared_events(config(), machine, never_asked())

      assert %{event: "parcel.delivered", document: "parcel", reason: :delay} = finding
      assert %Statifier.Parser.Location{start_line: 4} = finding.location
    end

    # Sabotage: narrowing delivery_reason/4's clause to a static delay
    # (`{:static, _}`) judges the delayexpr send by the lookup, which
    # flunks, and this goes red.
    test "a delayexpr is a delayed send and gives the same finding" do
      machine =
        compile!(
          courier_round(
            delayed(~s(delayexpr="reminder_after"), ~s(event="parcel.delivered"), @parcel_params)
          )
        )

      assert %{
               undeclared: [%{event: "parcel.delivered", document: "parcel", reason: :delay}],
               unchecked: []
             } = Contracts.undeclared_events(config(), machine, never_asked())
    end

    # Sabotage: checking the delay before literal_event/1 and
    # literal_document/1 in judge_send/3 (a :delay finding for any
    # delayed send) turns each of these into a finding and this goes red.
    test "a delayed send whose event or document is not literal keeps its unchecked reason" do
      variants = [
        {~s(eventexpr="outcome"), @parcel_params, :eventexpr},
        {"", @parcel_params, :no_event},
        {~s(event="parcel.delivered"), ~s(<param name="document" expr="receiver"/>),
         :document_expr},
        {~s(event="parcel.delivered"), ~s(<param name="key" expr="parcel_id"/>), :no_document}
      ]

      for delay_attr <- [~s(delay="2h"), ~s(delayexpr="reminder_after")],
          {event_attr, params, reason} <- variants do
        machine = compile!(courier_round(delayed(delay_attr, event_attr, params)))

        assert %{undeclared: [], unchecked: [%{reason: ^reason}]} =
                 Contracts.undeclared_events(config(), machine, never_asked()),
               "#{delay_attr} #{event_attr} #{params}"
      end
    end

    # Sabotage: answering :delay from delivery_reason/4 for every send
    # (widening its `delay != nil` guard to a nil delay too) makes the
    # undelayed send a finding and this goes red.
    test "an undelayed send beside a delayed one is judged by the lookup as before" do
      sends =
        to_parcel("parcel.scanned") <>
          delayed(~s(delay="2h"), ~s(event="parcel.delivered"), @parcel_params)

      assert %{undeclared: [%{event: "parcel.delivered", reason: :delay}], unchecked: []} =
               Contracts.undeclared_events(
                 config(),
                 compile!(courier_round(sends)),
                 declares_both()
               )
    end
  end

  describe "undeclared_events/3 selects only execution-target sends of the configuration's type" do
    # Sabotage: replacing the `node.target == {:static, execution_target()}`
    # test in classify/4 with `true` judges the route and targetexpr
    # sends too, and this goes red.
    test "a route send, another type, and a typeexpr or targetexpr send are not selected" do
      sends = """
      <send type="#{@type_string}" target="doorstep_photos" event="parcel.lost"/>
      <send type="depot:audit" target="execution" event="parcel.lost">
        <param name="document" expr="'parcel'"/>
      </send>
      <send typeexpr="processor" target="execution" event="parcel.lost">
        <param name="document" expr="'parcel'"/>
      </send>
      <send type="#{@type_string}" targetexpr="where" event="parcel.lost">
        <param name="document" expr="'parcel'"/>
      </send>
      """

      assert %{undeclared: [], unchecked: []} =
               Contracts.undeclared_events(
                 config(),
                 compile!(courier_round(sends)),
                 unpublished()
               )
    end

    # Sabotage: selecting on the target alone (dropping classify/4's
    # `is_binary(send_type)` guard and its type comparison) judges the
    # send and this goes red.
    test "a configuration with no send type selects nothing" do
      machine = compile!(courier_round(to_parcel("parcel.lost")))

      assert %{undeclared: [], unchecked: []} =
               Contracts.undeclared_events(
                 config(send_type: nil, route_adapters: %{}),
                 machine,
                 unpublished()
               )
    end
  end

  describe "undeclared_binding_events/2" do
    # Sabotage: dropping `binding_id` from the binding finding turns this
    # red.
    test "refuses a binding naming an undeclared event with its binding id" do
      bindings = [binding("scanned", "parcel.scanned"), binding("depot_lost", "parcel.lost")]

      assert [
               %{
                 event: "parcel.lost",
                 document: "parcel",
                 binding_id: "depot_lost",
                 reason: :undeclared
               }
             ] =
               Contracts.undeclared_binding_events(bindings, declares_both())
    end

    # Sabotage: answering :undeclared in judge/3's computed-set arm turns
    # this red.
    test "judges an undeclaring receiver by the computed set" do
      bindings = [binding("delivered", "parcel.delivered"), binding("depot_lost", "parcel.lost")]

      assert [%{binding_id: "depot_lost", reason: :undeclared_by_computed_set}] =
               Contracts.undeclared_binding_events(bindings, undeclared())
    end

    # Sabotage: answering nil for `{:error, :not_published}` in judge/3
    # passes the binding and this goes red.
    test "an unpublished receiver is a finding with the binding's id" do
      assert [%{binding_id: "scanned", document: "depot_round", reason: :not_published}] =
               Contracts.undeclared_binding_events(
                 [binding("scanned", "parcel.scanned", "depot_round")],
                 unpublished()
               )
    end

    # Sabotage: walking `Enum.reverse(bindings)` in
    # undeclared_binding_events/2 puts `second` first.
    test "reports findings in the order of the bindings" do
      bindings = [binding("first", "parcel.lost"), binding("second", "parcel.returned")]

      assert [%{binding_id: "first"}, %{binding_id: "second"}] =
               Contracts.undeclared_binding_events(bindings, declares_both())
    end

    # ADR-0008, decision 1: every binding is judged, a disabled one too.
    # Sabotage: filtering `bindings` to `enabled: true` in
    # undeclared_binding_events/2 drops `paused_lost` and this goes red.
    test "judges a disabled binding like any other" do
      {:ok, paused} =
        Binding.new(
          id: "paused_lost",
          source: "depot_feed",
          match: "event.kind == 'paused_lost'",
          key: "event.parcel_id",
          document: "parcel",
          event: "parcel.lost",
          enabled: false
        )

      assert [%{binding_id: "paused_lost", event: "parcel.lost", reason: :undeclared}] =
               Contracts.undeclared_binding_events([paused], declares_both())
    end
  end

  describe "check/3" do
    # A round with one of each: a route send to an unregistered route, a
    # send of an unregistered type, a typeexpr send, an eventexpr
    # execution-target send, a targetexpr send, and an execution-target
    # send of an undeclared event.
    @mixed_sends """
    <send type="#{@type_string}" target="returns_desk" event="parcel.returned"/>
    <send type="depot:audit" target="audit_log" event="parcel.seen"/>
    <send typeexpr="processor" target="execution" event="parcel.maybe"/>
    <send type="#{@type_string}" target="execution" eventexpr="outcome">
      <param name="document" expr="'parcel'"/>
    </send>
    <send type="#{@type_string}" targetexpr="where" event="parcel.somewhere"/>
    <send type="#{@type_string}" target="execution" event="parcel.lost">
      <param name="document" expr="'parcel'"/>
    </send>
    """

    # Sabotage: answering [] under `undeclared_binding_events` in check/3
    # turns this red.
    test "answers the five named lists" do
      config = config(bindings: [binding("depot_lost", "parcel.lost")])

      assert %{
               unsupported_types: [%{type: "depot:audit"}],
               unregistered_routes: [%{route: "returns_desk"}],
               unchecked: [_, _, _],
               undeclared_events: [%{event: "parcel.lost", reason: :undeclared}],
               undeclared_binding_events: [%{binding_id: "depot_lost", reason: :undeclared}]
             } =
               report =
               Contracts.check(config, compile!(courier_round(@mixed_sends)), declares_both())

      assert report |> Map.keys() |> Enum.sort() ==
               [
                 :unchecked,
                 :undeclared_binding_events,
                 :undeclared_events,
                 :unregistered_routes,
                 :unsupported_types
               ]
    end

    # Sabotage: concatenating the two unchecked lists without the sort_by
    # in check/3 puts :targetexpr before :eventexpr and this goes red.
    test "carries every unchecked entry once, in document order" do
      report = Contracts.check(config(), compile!(courier_round(@mixed_sends)), declares_both())

      assert [%{reason: :typeexpr}, %{reason: :eventexpr}, %{reason: :targetexpr}] =
               report.unchecked
    end

    # Sabotage: dropping delivery_reason/4's `delay != nil` clause passes
    # the declared delayed send and empties `undeclared_events`.
    test "carries a delayed send's :delay finding under undeclared_events" do
      sends = delayed(~s(delay="2h"), ~s(event="parcel.delivered"), @parcel_params)
      report = Contracts.check(config(), compile!(courier_round(sends)), declares_both())

      assert %{
               undeclared_events: [
                 %{event: "parcel.delivered", document: "parcel", reason: :delay}
               ],
               unchecked: [],
               unregistered_routes: [],
               unsupported_types: [],
               undeclared_binding_events: []
             } = report
    end

    # Sabotage: dropping each entry's location from the unsupported_types
    # list in check/3 makes it differ from the direct call and this goes
    # red.
    test "composes both route functions unchanged" do
      config = config()
      machine = compile!(courier_round(@mixed_sends))
      report = Contracts.check(config, machine, declares_both())

      assert report.unsupported_types == Routes.unsupported_types(config, machine)
      assert report.unregistered_routes == Routes.unregistered(config, machine).unregistered
    end
  end
end
