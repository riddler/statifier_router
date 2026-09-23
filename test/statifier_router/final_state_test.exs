defmodule StatifierRouter.FinalStateTest do
  use ExUnit.Case, async: true, group: :database

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Machine
  alias StatifierPersistence.Storage
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-21 08:00:00.000000Z]
  @scope "7c1e"
  @type_string "myapp:sink"
  @route "joined_records"

  # The chart pattern this bead documents: the `<final>` the join settles
  # in sends on its way in, so the send is emitted on the step that
  # finishes the execution. The `<donedata>` beside it is what an
  # `:on_complete` hook would be handed; the test that uses this document
  # configures none, so the only thing its route sees is the send. The two
  # have the same shape, one `via` param, with different values, so a test
  # can tell which one it read.
  @sinking """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <transition event="click" target="joined"/>
    </state>
    <final id="joined">
      <onentry>
        <send type="myapp:sink" target="joined_records" event="pair.joined">
          <param name="via" expr="'onentry'"/>
        </send>
      </onentry>
      <donedata>
        <param name="via" expr="'donedata'"/>
      </donedata>
    </final>
  </scxml>
  """

  # The same join with no outbound send at all: whatever a route sees under
  # this document came from the completion hook.
  @plain """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <transition event="click" target="joined"/>
    </state>
    <final id="joined">
      <donedata>
        <param name="via" expr="'donedata'"/>
      </donedata>
    </final>
  </scxml>
  """

  # A final with nothing in it: the hook still fires, and what it hands
  # over is statifier's no-value marker, `:undefined`, not `nil`.
  @bare """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="joined"/>
    </state>
    <final id="joined"/>
  </scxml>
  """

  # A chart whose initial configuration is already a <final>: the execution
  # is terminal on the answer to `Executions.create/4` and never takes a
  # step, so that create answer is the only place its donedata ever exists.
  @at_init """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="joined">
    <final id="joined">
      <donedata>
        <param name="via" expr="'at_init'"/>
      </donedata>
    </final>
  </scxml>
  """

  @documents %{
    "sinking_join" => @sinking,
    "plain_join" => @plain,
    "bare_join" => @bare,
    "at_init_join" => @at_init
  }

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "the <final> onentry send" do
    # sabotage: the chart's <onentry> block was emptied of its <send> ->
    # nothing reached the route on the finishing step and the assertion on
    # the routed message failed, red; restored, green.
    test "is emitted on the step that finishes the execution" do
      config = config("sinking_join")
      execution = start(config)

      refute_received {:routed, _route_config, _event, _key}

      assert {:delivered, "clicks_to_join", ^execution} = routed(config, click())

      assert_received {:routed, _route_config, event, key}
      assert event.name == "pair.joined"
      assert event.data == %{"via" => "onentry"}

      # The key an ordinary send composes: the scope half is the executor
      # seam's execution id, and the send carries an ordinal.
      assert {^execution, %{send_id: _send_id}, ordinal} = key
      assert is_integer(ordinal)

      assert {:ok, %{status: :completed}} = Storage.fetch_execution(config.store, execution)
    end
  end

  describe "Config.new/1 and :on_complete" do
    test "accepts a registered route name" do
      assert {:ok, %Config{on_complete: @route}} =
               config_options(on_complete: @route) |> Config.new()
    end

    # sabotage: on_complete/2 answered {:ok, name} without consulting the
    # registry -> an unregistered name was accepted and would have missed
    # at run time, red; restored, green.
    test "refuses a name no route is registered under" do
      assert Config.new(config_options(on_complete: "nowhere")) ==
               {:error, {:unregistered_on_complete, "nowhere"}}
    end

    test "refuses the reserved execution-target name, which is never a route" do
      assert Config.new(config_options(on_complete: "execution")) ==
               {:error, {:unregistered_on_complete, "execution"}}
    end

    test "refuses a value that is not a non-empty string" do
      assert Config.new(config_options(on_complete: :joined_records)) ==
               {:error, {:invalid_value, :on_complete, :joined_records}}

      assert Config.new(config_options(on_complete: "")) ==
               {:error, {:invalid_value, :on_complete, ""}}
    end

    test "defaults to nil" do
      assert {:ok, %Config{on_complete: nil}} = Config.new(config_options([]))
    end
  end

  describe "the completion hook" do
    # sabotage: complete/3 handed the route `data: nil` - exactly what a
    # second read of the execution record would have answered, since
    # StatifierPersistence.Execution.from_record/1 sets the field to `nil`
    # on every struct built from a stored row -> this test and the
    # no-donedata one below both went red; restored, green. That read is
    # what this bead's own fallback clause proposed, and it fails silently:
    # it succeeds and returns nothing.
    test "hands the step's donedata to the route once, on the delivery that finishes the execution" do
      config = config("plain_join", on_complete: @route)
      execution = start(config)

      refute_received {:routed, _route_config, _event, _key}

      assert {:delivered, "clicks_to_join", ^execution} = routed(config, click())

      assert_received {:routed, _route_config, event, key}
      assert event.name == "done.execution"
      assert event.data == %{"via" => "donedata"}
      assert event.origin == execution

      # ADR-0005 decision 4's key with no send behind it: the scope half is
      # the execution, the ordinal is nil, and the three fields that belong
      # to a `<send>` element are empty.
      assert {^execution, position, nil} = key
      assert %{send_id: nil, c_index: nil, owner: nil} = position
      assert is_integer(position.macrostep)
      assert is_integer(position.microstep)
      assert is_integer(position.round)

      refute_received {:routed, _route_config, _event, _key}
    end

    # sabotage: finished/6 fired the hook too -> the second click, which
    # this path settles as `dropped: finished`, routed a second
    # `done.execution` and the refute below caught it, red; restored,
    # green.
    test "does not fire again for a later delivery to the finished execution" do
      config = config("plain_join", on_complete: @route)
      execution = start(config)

      assert {:delivered, "clicks_to_join", ^execution} = routed(config, click())

      assert_received {:routed, _route_config, _event, _key}

      assert {:dropped, "clicks_to_join", :finished} =
               routed(config, click("ad_events/3/1108"))

      refute_received {:routed, _route_config, _event, _key}
    end

    test "hands over statifier's no-value marker for a <final> that carries no donedata" do
      config = config("bare_join", on_complete: @route)

      assert {:created_and_delivered, "impressions_to_join", _execution} =
               routed(config, impression())

      assert_received {:routed, _route_config, event, _key}
      assert event.name == "done.execution"
      # `Statifier.Interpreter`'s donedata fold answers `:undefined` where
      # there is no `<donedata>`, and the hook carries what the step
      # answered rather than normalizing it.
      assert event.data == :undefined
    end

    # sabotage: the `:ok <- complete(config, execution, state)` clause was
    # removed from create/6 outright, leaving the create door with no hook
    # at all -> this test alone went red, on the assert_received below, and
    # the other eleven in this file stayed green; restored, green. That is
    # the mutation this test exists for: before it the create door's arm
    # had no coverage, and the whole suite passed without it.
    test "fires on the create answer for a chart already final at initialization" do
      config = config("at_init_join", on_complete: @route)

      # `create/4` answers terminal and the delivery never reaches `step/5`,
      # so this event is the created execution's first and last.
      assert {:dropped, "impressions_to_join", :finished} = routed(config, impression())

      assert_received {:routed, _route_config, event, key}
      assert event.name == "done.execution"
      assert event.data == %{"via" => "at_init"}

      assert {execution_id, position, nil} = key
      assert event.origin == execution_id
      assert {:ok, %{status: :completed}} = Storage.fetch_execution(config.store, execution_id)

      assert %{send_id: nil, c_index: nil, owner: nil} = position
      assert is_integer(position.macrostep)
      assert is_integer(position.microstep)
      assert is_integer(position.round)

      refute_received {:routed, _route_config, _event, _key}
    end

    test "fires nothing when no route is configured" do
      config = config("plain_join")
      execution = start(config)

      assert {:delivered, "clicks_to_join", ^execution} = routed(config, click())

      refute_received {:routed, _route_config, _event, _key}
    end

    # sabotage: complete/3 discarded the route's {:error, reason} and
    # answered :ok -> the delivery committed with the hand-off lost and
    # this assertion failed, red; restored, green.
    test "settles the delivery as an error, writing no ledger row, when the route refuses" do
      config = config("plain_join", on_complete: @route, answer: {:error, :queue_down})
      execution = start(config)
      before = length(ledger(config))

      assert StatifierRouter.route(config, click(), now: @now) ==
               {:error, {:on_complete, @route, :queue_down}}

      assert length(ledger(config)) == before
      assert {:ok, %{status: :active}} = Storage.fetch_execution(config.store, execution)
    end
  end

  # ------------------------------------------------------------------

  defp start(config) do
    assert {:created_and_delivered, "impressions_to_join", execution} =
             routed(config, impression())

    execution
  end

  # The two bindings share one source, so every event is offered to both
  # and the one that does not match answers `{:no_match, binding_id}`.
  # This is the outcome of the binding that did.
  defp routed(config, event) do
    {:ok, outcomes} = StatifierRouter.route(config, event, now: @now)
    assert [outcome] = Enum.reject(outcomes, &match?({:no_match, _binding}, &1))
    outcome
  end

  defp config(document, opts \\ []) do
    {answer, opts} = Keyword.pop(opts, :answer, :ok)

    {:ok, config} =
      document
      |> config_options(answer)
      |> Keyword.merge(opts)
      |> Config.new()

    executor = fn effect, context ->
      StatifierRouter.SendHandler.handle_effect(config, effect, context)
    end

    %{config | executor: executor}
  end

  defp config_options(opts) when is_list(opts),
    do: Keyword.merge(config_options("plain_join", :ok), opts)

  defp config_options(document, answer) do
    machines = machines()
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)

    {:ok, static} =
      Static.new(for {name, machine} <- machines, into: %{}, do: {{@scope, name}, machine})

    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})

    [
      repo: TestRepo,
      store: store,
      executor: fn _effect, _context -> :ok end,
      resolver: static,
      chart_resolver: fn content_hash -> Map.fetch(by_hash, content_hash) end,
      bindings: bindings(document),
      send_type: @type_string,
      route_adapters: %{@route => {RecordingRoute, %{pid: self(), answer: answer}}}
    ]
  end

  defp machines do
    for {document, source} <- @documents, into: %{} do
      {:ok, machine} = Statifier.compile(source)
      {document, machine}
    end
  end

  defp bindings(document) do
    [
      %{
        id: "impressions_to_join",
        source: "ad_events",
        match: "event.kind == 'impression'",
        key: "event.impression_id",
        document: document,
        event: "impression",
        data: ["impression_id"]
      },
      %{
        id: "clicks_to_join",
        source: "ad_events",
        match: "event.kind == 'click'",
        key: "event.impression_id",
        document: document,
        event: "click",
        data: ["impression_id"]
      }
    ]
  end

  defp impression do
    %{
      scope: @scope,
      message_id: "ad_events/3/1042",
      source: "ad_events",
      data: %{"kind" => "impression", "impression_id" => "imp_7f3a"}
    }
  end

  defp click(message_id \\ "ad_events/3/1107") do
    %{
      scope: @scope,
      message_id: message_id,
      source: "ad_events",
      data: %{"kind" => "click", "impression_id" => "imp_7f3a"}
    }
  end

  defp ledger(config),
    do: TestRepo.all(from(l in Config.queryable(config, Ledger), order_by: l.id))
end
