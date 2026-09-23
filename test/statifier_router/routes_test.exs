defmodule StatifierRouter.RoutesTest do
  use ExUnit.Case, async: true

  alias StatifierRouter.Config
  alias StatifierRouter.DeliveryFixtures
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.Routes
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo

  doctest StatifierRouter.Routes

  @type_string "myapp:sink"

  # The join's outbound half with an expression in `target` on a third
  # send, and one send of a type the host never registered.
  @mixed """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="joining">
    <state id="joining">
      <onentry>
        <send type="myapp:sink" target="joined_records" event="joined"/>
        <send type="myapp:sink" target="dead_letter" event="orphaned"/>
        <send type="myapp:sink" targetexpr="sink" event="chosen"/>
        <send type="myapp:audit" target="audit_log" event="seen"/>
        <send typeexpr="processor" target="joined_records" event="maybe"/>
        <send target="#_internal" event="internal"/>
      </onentry>
    </state>
  </scxml>
  """

  defp config(opts \\ []) do
    {:ok, config} =
      [
        repo: TestRepo,
        delivery: MyApp.Delivery,
        send_type: @type_string,
        route_adapters: %{"joined_records" => {RecordingRoute, %{}}}
      ]
      |> Keyword.merge(opts)
      |> Config.new()

    config
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  describe "unregistered/2" do
    # Sabotage: dropping the `Map.has_key?(config.route_adapters, name)`
    # arm of check_target/3 makes `joined_records` a finding too and this
    # goes red.
    test "lists an unregistered literal route and nothing for a registered one" do
      report = Routes.unregistered(config(), compile!(DeliveryFixtures.join_sends()))

      assert [%{route: "dead_letter"}] = report.unregistered
      assert report.unchecked == []
    end

    # Sabotage: reversing the accumulated lists twice (dropping the
    # Enum.reverse in unregistered/2) puts `second` before `first`.
    test "reports findings in document order" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
          <onentry>
            <send type="myapp:sink" target="first" event="one"/>
            <send type="myapp:sink" target="second" event="two"/>
          </onentry>
        </state>
      </scxml>
      """

      assert [%{route: "first"}, %{route: "second"}] =
               Routes.unregistered(config(), compile!(source)).unregistered
    end

    # Sabotage: reporting a `{:compiled, _, _}` target as a finding rather
    # than as unchecked empties `unchecked` and lengthens `unregistered`.
    test "reports a targetexpr send as unchecked, never as a finding" do
      report = Routes.unregistered(config(), compile!(@mixed))

      assert [%{route: "dead_letter"}] = report.unregistered
      assert [%{reason: :targetexpr}, %{reason: :typeexpr}] = report.unchecked
    end

    # Sabotage: matching a send's location to its own `<send>` element is
    # what makes a finding actionable; pointing every finding at the state
    # instead makes the two lines equal and this goes red.
    test "carries each finding's own <send> element location" do
      [finding] = Routes.unregistered(config(), compile!(@mixed)).unregistered

      assert %Statifier.Parser.Location{start_line: line} = finding.location
      assert line == 5
    end

    # Sabotage: dropping the `name == SendHandler.execution_target()` arm
    # makes the reserved name a finding, which ADR-0006 section 1 forbids.
    test "never reports the reserved execution target" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
          <onentry>
            <send type="myapp:sink" target="#{SendHandler.execution_target()}" event="pair.joined">
              <param name="document" expr="'placement_counter'"/>
            </send>
          </onentry>
        </state>
      </scxml>
      """

      assert %{unregistered: [], unchecked: []} =
               Routes.unregistered(config(), compile!(source))
    end

    # Sabotage: answering `%{route: name}` for a send with no target at all
    # raises rather than reporting, because there is no name to report.
    test "reports a send of this type that writes no target" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
          <onentry><send type="myapp:sink" event="nowhere"/></onentry>
        </state>
      </scxml>
      """

      assert %{unregistered: [%{route: nil}]} = Routes.unregistered(config(), compile!(source))
    end

    # Sabotage: claiming every literal-typed send (replacing classify/3's
    # whole `is_binary(config.send_type) and type == config.send_type`
    # condition with `true`) makes both sends findings and this goes red.
    # Dropping only the `is_binary/1` guard does NOT: a send with no type
    # is caught by classify/3's nil clause first, and a literal type is
    # always a string, which never equals nil. The guard is defensive-only
    # and says in classify/3 why it is kept.
    test "claims nothing when the configuration registers no send type" do
      config = config(send_type: nil, route_adapters: %{})

      assert %{unregistered: [], unchecked: []} =
               Routes.unregistered(config, compile!(DeliveryFixtures.join_sends()))
    end

    # Sabotage: walking each state's `<onentry>`/`<onexit>` blocks (their
    # `content` indices) in unregistered/2 instead of the machine's flat
    # `contents` tuple sees only the `<if>` node, never the send inside
    # its branch, and this goes red.
    test "finds a send nested inside an if element" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <datamodel><data id="overdue" expr="true"/></datamodel>
        <state id="on_loan">
          <onentry>
            <if cond="overdue">
              <send type="myapp:sink" target="overdue_notices" event="loan.overdue"/>
            </if>
          </onentry>
        </state>
      </scxml>
      """

      assert %{unregistered: [%{route: "overdue_notices"}], unchecked: []} =
               Routes.unregistered(config(), compile!(source))
    end

    # Sabotage: the same state-block walk in unregistered/2 never reaches
    # a transition's executable content, so this send is lost and this
    # goes red.
    test "finds a send on a transition" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
          <transition event="loan.returned" target="returned">
            <send type="myapp:sink" target="hold_shelf" event="copy.returned"/>
          </transition>
        </state>
        <final id="returned"/>
      </scxml>
      """

      assert %{unregistered: [%{route: "hold_shelf"}], unchecked: []} =
               Routes.unregistered(config(), compile!(source))
    end

    # Sabotage: a scope override that changed a route's existence rather
    # than its configuration would make this scope-dependent; ADR-0005
    # decision 2 forbids that, so one answer serves every scope.
    test "a scope override changes no finding" do
      config =
        config(route_overrides: %{"staging" => %{"joined_records" => %{sink: "other"}}})

      assert [%{route: "dead_letter"}] =
               Routes.unregistered(config, compile!(DeliveryFixtures.join_sends())).unregistered
    end
  end

  describe "unsupported_types/2" do
    # Sabotage: reading `:routes` instead of `:send_types` off
    # `:persistence_options` answers `nil` and every non-built-in type
    # becomes unsupported, so `myapp:sink` appears too.
    test "lists a type outside the configuration's registered set" do
      assert [%{type: "myapp:audit"}] =
               Routes.unsupported_types(config(), compile!(@mixed))
    end

    # Sabotage: answering `nil` for the snapshot instead of reading
    # `:send_types` makes every non-built-in type unsupported, so
    # `myapp:sink` appears here and this goes red.
    test "lists nothing when every literal type is registered" do
      assert [] == Routes.unsupported_types(config(), compile!(DeliveryFixtures.join_sends()))
    end

    # A typeexpr send is judged by neither half: the engine's function
    # cannot see one, and this package reports it as unchecked instead.
    # Sabotage: dropping the `{:compiled, _, _}` arm of classify/3 so a
    # typeexpr send falls through untouched empties `unchecked` and this
    # goes red.
    test "leaves a typeexpr send to unregistered/2's unchecked list" do
      types = Routes.unsupported_types(config(), compile!(@mixed))
      report = Routes.unregistered(config(), compile!(@mixed))

      assert Enum.map(types, & &1.type) == ["myapp:audit"]
      assert Enum.any?(report.unchecked, &(&1.reason == :typeexpr))
      refute Enum.any?(report.unregistered, &(&1.route == "joined_records"))
    end

    # Sabotage: a configuration that declares no send type carries no
    # snapshot, which the engine reads as the built-in set only.
    test "judges an undeclared configuration against the built-in set" do
      config = config(send_type: nil, route_adapters: %{})

      assert [%{type: "myapp:sink"}, %{type: "myapp:sink"}] =
               Routes.unsupported_types(config, compile!(DeliveryFixtures.join_sends()))
    end
  end
end
