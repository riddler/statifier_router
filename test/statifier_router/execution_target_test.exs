defmodule StatifierRouter.ExecutionTargetTest do
  use ExUnit.Case, async: true, group: :database

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Machine
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.RecordingTimerQueue
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-21 08:00:00.000000Z]
  @scope "7c1e"
  @type_string "myapp:router"

  # The join of ADR-0001's example, with no outbound half: the sender of
  # every hand-built send below is one of these, so its address row exists
  # and nothing else fires while a test drives one send at a time.
  @plain """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # ADR-0006's own example: the join tells a placement counter that an
  # impression and its click joined. `placement_id` is the message;
  # `document` and `key` are the envelope.
  @sending """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <onentry>
        <send type="myapp:router" target="execution" event="pair.joined">
          <param name="document" expr="'placement_counter'"/>
          <param name="key" expr="'home_top'"/>
          <param name="placement_id" expr="'home_top'"/>
        </send>
      </onentry>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # The same send with no `document` param: a refusal the sender hears,
  # written while the sender's own step is still open.
  @malformed """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <onentry>
        <send type="myapp:router" target="execution" event="pair.joined">
          <param name="key" expr="'home_top'"/>
        </send>
      </onentry>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # The placement counter: it counts every join its charts send it and
  # stays active, so a second join reaches the same execution.
  @counter """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="counting">
    <state id="counting">
      <transition event="pair.joined" target="counting"/>
    </state>
  </scxml>
  """

  # The same send naming a document the host's resolver does not know: the
  # delivery fails inside the sender's own step, which is the shape the
  # nested transaction makes hazardous.
  @unresolved """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <onentry>
        <send type="myapp:router" target="execution" event="pair.joined">
          <param name="document" expr="'unknown_counter'"/>
          <param name="key" expr="'home_top'"/>
        </send>
      </onentry>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # A counter that is finished as soon as it is created.
  @instant """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="done">
    <final id="done"/>
  </scxml>
  """

  @documents %{
    "plain_join" => @plain,
    "sending_join" => @sending,
    "malformed_join" => @malformed,
    "unresolved_join" => @unresolved,
    "placement_counter" => @counter,
    "instant_counter" => @instant
  }

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  describe "the address the send names" do
    # sabotage: to_execution/3 took the scope from the send's data rather
    # than from the sender's address row -> the counter resolved under no
    # scope and the delivery created nothing under 7c1e, red; restored,
    # green.
    test "creates the execution its address names, under if_absent, and delivers the builder's event" do
      config = config("sending_join")

      assert {:ok, [{:created_and_delivered, "impressions_to_join", sender}]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert [counter] = counter_addresses(config)
      assert counter.scope == @scope
      assert counter.key == "home_top"
      assert counter.execution_id != sender

      assert {:ok, [%{event: event, door: "step"}]} =
               Executions.inputs(config.store, counter.execution_id)

      assert event.name == "pair.joined"
      # ADR-0006, section 4: the envelope params are consumed and the
      # message travels.
      assert event.data == %{"placement_id" => "home_top"}
      assert event.origin == "#_scxml_" <> sender
      assert event.origintype == @type_string
    end

    # sabotage: envelope/3 skipped its self-address check -> the join was
    # delivered to its own address instead of being refused, red;
    # restored, green.
    test "refuses a send to the sender's own address, with a row that names it" do
      config = config("plain_join")
      sender = sender(config)

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(%{"document" => "plain_join", "key" => "imp_7f3a"})},
               seam(sender)
             ) == {:error, {:send_refused, :self_address}}

      assert %Ledger{
               binding_id: "execution",
               scope: @scope,
               outcome: "send_refused",
               reason: "self_address",
               key: "imp_7f3a",
               execution_id: ^sender
             } = List.last(ledger(config))
    end

    # sabotage: to_execution/3 answered the sender's own execution id as
    # the scope when by_execution/2 found no row -> a send from an
    # addressless execution wrote a ledger row under a scope that is not
    # one, red; restored, green.
    test "refuses a sender with no address row, and records nothing for it" do
      config = config("plain_join")
      _sender = sender(config)
      before = length(ledger(config))

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(%{"document" => "placement_counter", "key" => "home_top"})},
               seam("ex_no_address")
             ) == {:error, {:send_refused, :unaddressed_sender}}

      assert length(ledger(config)) == before
      assert counter_addresses(config) == []
    end
  end

  describe "the miss" do
    # sabotage: create_mode/2 read every `create` param as :if_absent ->
    # a send written `never` created the counter it was told not to, red;
    # restored, green.
    test "records dropped: no_execution under never, creates nothing, and tells the sender" do
      config = config("plain_join")
      sender = sender(config)

      assert SendHandler.handle_effect(
               config,
               {:send,
                send_effect(%{
                  "document" => "placement_counter",
                  "key" => "home_top",
                  "create" => "never"
                })},
               seam(sender)
             ) == {:error, {:send_undelivered, :no_execution}}

      assert counter_addresses(config) == []

      assert %Ledger{
               binding_id: "execution",
               scope: @scope,
               outcome: "dropped: no_execution",
               key: "home_top",
               execution_id: nil,
               reason: nil
             } = List.last(ledger(config))
    end

    # sabotage: reported/1 answered :ok for a {:dropped, _, :finished}
    # outcome -> a chart sending to a finished execution was told its send
    # landed, red; restored, green.
    test "records dropped: finished for a terminal target and tells the sender" do
      config = config("plain_join")
      sender = sender(config)

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(%{"document" => "instant_counter", "key" => "home_top"})},
               seam(sender)
             ) == {:error, {:send_undelivered, :finished}}

      assert [%Address{terminal_seen_at: %DateTime{}}] =
               addresses(config, "instant_counter")

      assert %Ledger{outcome: "dropped: finished", key: "home_top"} = List.last(ledger(config))
    end

    # sabotage: message_id/1 dropped the ordinal from the composed id ->
    # two different sends of one step shared a dedupe row and the second
    # was a duplicate, red; restored, green.
    test "a replayed send is a duplicate and steps nothing a second time" do
      config = config("plain_join")
      sender = sender(config)
      effect = send_effect(%{"document" => "placement_counter", "key" => "home_top"})

      assert SendHandler.handle_effect(config, {:send, effect}, seam(sender)) == :ok
      assert [counter] = counter_addresses(config)
      assert SendHandler.handle_effect(config, {:send, effect}, seam(sender)) == :ok

      assert {:ok, [_one_step]} = Executions.inputs(config.store, counter.execution_id)

      # A second send from the same execution at a different ordinal is new
      # work, not a replay: the same counter is stepped again.
      assert SendHandler.handle_effect(
               config,
               {:send, %{effect | ordinal: 2}},
               seam(sender)
             ) == :ok

      assert {:ok, [_first, _second]} = Executions.inputs(config.store, counter.execution_id)
      assert [^counter] = counter_addresses(config)

      assert ["created_and_delivered", "duplicate", "delivered"] ==
               config
               |> ledger()
               |> Enum.filter(&(&1.binding_id == "execution"))
               |> Enum.map(& &1.outcome)
    end
  end

  describe "a refused envelope" do
    # sabotage: non_empty/3 accepted a missing param as the empty string ->
    # a send with no document resolved an address under "" instead of being
    # refused, red; restored, green.
    test "refuses a missing document and a missing key, with key and execution_id empty" do
      config = config("plain_join")
      sender = sender(config)

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(%{"key" => "home_top"})},
               seam(sender)
             ) == {:error, {:send_refused, :document}}

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(%{"document" => "placement_counter"})},
               seam(sender)
             ) == {:error, {:send_refused, :key}}

      assert [
               %Ledger{outcome: "send_refused", reason: "document", key: nil, execution_id: nil},
               %Ledger{outcome: "send_refused", reason: "key", key: nil, execution_id: nil}
             ] = config |> ledger() |> Enum.filter(&(&1.outcome == "send_refused"))
    end

    # sabotage: create_mode/2 accepted "always_new" as a mode -> the third
    # mode ADR-0006 does not offer wrote an execution the key does not
    # address, red; restored, green.
    test "refuses a create the record does not offer, with the key set" do
      config = config("plain_join")
      sender = sender(config)

      assert SendHandler.handle_effect(
               config,
               {:send,
                send_effect(%{
                  "document" => "placement_counter",
                  "key" => "home_top",
                  "create" => "always_new"
                })},
               seam(sender)
             ) == {:error, {:send_refused, :create}}

      assert %Ledger{
               outcome: "send_refused",
               reason: "create",
               key: "home_top",
               execution_id: nil
             } =
               List.last(ledger(config))

      assert counter_addresses(config) == []
    end

    # sabotage: refused/6 raised instead of answering an error -> the
    # refusal rolled the sender's delivery back and its execution had no
    # input row, red; restored, green.
    test "the sender's own step commits although its send was refused" do
      config = config("malformed_join")

      assert {:ok, [{:created_and_delivered, "impressions_to_join", sender}]} =
               StatifierRouter.route(config, impression(), now: @now)

      assert {:ok, [%{event: %{name: "impression"}}]} =
               Executions.inputs(config.store, sender)

      assert %Ledger{outcome: "send_refused", reason: "document"} =
               config |> ledger() |> Enum.find(&(&1.binding_id == "execution"))
    end

    # The refusal row is written inside the sender's own transaction, where
    # a failed insert leaves that transaction aborted. LedgerFailingRepo
    # makes the send_refused insert fail in Postgres.
    #
    # sabotage: refused/6 wrote its row with a bare insert! again, outside
    # write_guarded/3 (the shape before its bracket) -> the failed insert
    # raised out of the executor and took the sender's step down, so
    # route/3 raised instead of answering an outcome, red; restored, green.
    test "a refusal row that cannot be written leaves the sender's step standing" do
      config = failing_ledger(config("malformed_join"))

      assert {:ok, [{:created_and_delivered, "impressions_to_join", sender}]} =
               StatifierRouter.route(config, impression(), now: @now)

      # The refusal is still reported, whatever the ledger did.
      assert_received {:handled, {:error, {:send_refused, :document}}}

      assert {:ok, [%{event: %{name: "impression"}}]} =
               Executions.inputs(config.store, sender)

      # The row rolled back to its savepoint; the delivery's own row stands.
      assert [%Ledger{outcome: "created_and_delivered", execution_id: ^sender}] = ledger(config)
    end
  end

  describe "a delivery that errors inside the sending step" do
    # sabotage: deliver_event/4 settled through the rollback door deliver/4
    # used to take, `c:Ecto.Repo.rollback/1` inside the transaction,
    # instead of its own savepoint -> the nested rollback aborted the
    # sender's transaction, the persist tail raised
    # DBConnection.ConnectionError out of the step and route/3 never
    # returned an outcome, red; restored, green.
    test "reports the real reason, leaves the sender's step standing, and leaves no target row" do
      config = config("unresolved_join")

      assert {:ok, [{:created_and_delivered, "impressions_to_join", sender}]} =
               StatifierRouter.route(config, impression(), now: @now)

      # The reason the delivery failed for, not a bare :rollback and not a
      # raise (ADR-0005, section 7; ADR-0006, section 3).
      assert_received {:handled, {:error, {:unresolved_document, "unknown_counter", _reason}}}

      # The sender's step stands: its execution committed with the event
      # that fired the send in its input log.
      assert {:ok, [%{event: %{name: "impression"}}]} = Executions.inputs(config.store, sender)

      # And the target side left nothing behind: the address row the
      # delivery inserted before the resolver refused is gone with the
      # savepoint.
      assert addresses(config, "unknown_counter") == []
      assert dedupe_rows(config) == ["impressions_to_join"]
    end
  end

  describe "a delayed send to the execution target" do
    # sabotage: enqueue/4's execution-target clause removed -> the send
    # fell through to the route registry and was answered
    # {:unregistered_route, "execution"} with a `route` row, red; restored,
    # green.
    # sabotage: the clause answered its reason without record_refusal/4 ->
    # the sender was told but the ledger held no `delay` row, red; restored,
    # green.
    test "is refused by the delay reason, recorded under the sender's scope, and never queued" do
      config = config("plain_join", timer_queue: {RecordingTimerQueue, %{}})
      sender = sender(config)

      assert SendHandler.handle_effect(config, {:send_delayed, delayed_effect()}, seam(sender)) ==
               {:error, {:send_refused, :delay}}

      assert RecordingTimerQueue.entries() == []

      assert [
               %Ledger{
                 binding_id: "execution",
                 scope: @scope,
                 outcome: "send_refused",
                 reason: "delay",
                 key: nil,
                 execution_id: nil,
                 message_id: message_id
               }
             ] = config |> ledger() |> Enum.filter(&(&1.outcome == "send_refused"))

      assert [^sender | _rest] = String.split(message_id, "/")
      assert counter_addresses(config) == []
    end

    # sabotage: enqueue/4's execution-target clause answered
    # {:send_refused, :unaddressed_sender} when the sender had no address
    # row -> the sender heard a missing address rather than the delay that
    # is refused whatever the address, red; restored, green.
    test "tells a sender with no address row the same reason, and records nothing for it" do
      config = config("plain_join", timer_queue: {RecordingTimerQueue, %{}})
      _sender = sender(config)
      before = length(ledger(config))

      assert SendHandler.handle_effect(
               config,
               {:send_delayed, delayed_effect()},
               seam("ex_no_address")
             ) == {:error, {:send_refused, :delay}}

      assert length(ledger(config)) == before
      assert RecordingTimerQueue.entries() == []
    end

    # sabotage: the execution-target branch moved out of enqueue/4 into
    # handle_effect/3's {:send_delayed, ...} arm -> perform/2 on this shape
    # missed the registry and answered {:unregistered_route, "execution"},
    # red; restored, green.
    test "answers the same reason on the send-processor shape" do
      on_exit(&SendHandler.delete_config/0)
      effect = delayed_effect()
      event = SendEvent.build(effect, "session_1")

      assert {:ok, [{:handler, SendHandler, payload}]} =
               SendHandler.deliver(effect, event, %{session_id: "session_1"})

      :ok =
        SendHandler.put_config(config("plain_join", timer_queue: {RecordingTimerQueue, %{}}))

      assert SendHandler.perform(payload, %{session_id: "session_1"}) ==
               {:error, {:send_refused, :delay}}

      assert RecordingTimerQueue.entries() == []
    end
  end

  describe "an immediate send on the send-processor shape" do
    # sabotage: perform/2's execution-target clause removed -> the send
    # went through the route registry and was answered
    # {:unregistered_route, "execution"}, with no counter created, red;
    # restored, green.
    # sabotage: the clause passed the host's `:processor_scope` string to
    # to_execution/3 as the sender -> no address row was found and the send
    # was refused as unaddressed_sender, red; restored, green.
    test "delivers through the address the sender's session id names, under that row's scope" do
      config = config("plain_join", processor_scope: "not_the_senders_scope")
      sender = sender(config)

      assert perform_immediate(
               config,
               send_effect(%{
                 "document" => "placement_counter",
                 "key" => "home_top",
                 "placement_id" => "home_top"
               }),
               sender
             ) == :ok

      assert [counter] = counter_addresses(config)
      # ADR-0006, section 1: the scope is read from the sender's own
      # address row, never from the host's `:processor_scope`.
      assert counter.scope == @scope
      assert counter.key == "home_top"

      assert {:ok, [%{event: event, door: "step"}]} =
               Executions.inputs(config.store, counter.execution_id)

      assert event.name == "pair.joined"
      assert event.data == %{"placement_id" => "home_top"}
      assert event.origin == "#_scxml_" <> sender
      assert event.origintype == @type_string
    end

    # sabotage: perform/2's execution-target clause called
    # processor_scope/1 before to_execution/3, as resolve/3 does for a
    # route -> the host's fun was asked for a send it plays no part in,
    # red; restored, green.
    test "never asks the host's scope fun for a send to the reserved target" do
      pid = self()

      config =
        config("plain_join",
          processor_scope: fn ->
            send(pid, :processor_scope_asked)
            "not_the_senders_scope"
          end
        )

      sender = sender(config)

      assert perform_immediate(
               config,
               send_effect(%{"document" => "placement_counter", "key" => "home_top"}),
               sender
             ) == :ok

      refute_received :processor_scope_asked
      assert [%Address{scope: @scope}] = counter_addresses(config)
    end

    # sabotage: to_execution/3 answered :ok for a sender with no address
    # row -> the refusal was swallowed and the host had nothing to report,
    # red; restored, green.
    test "refuses a session id that names no address row by the executor seam's name, and records nothing" do
      config = config("plain_join")
      _sender = sender(config)
      before = length(ledger(config))

      assert perform_immediate(
               config,
               send_effect(%{"document" => "placement_counter", "key" => "home_top"}),
               "session_no_address"
             ) == {:error, {:send_refused, :unaddressed_sender}}

      assert length(ledger(config)) == before
      assert counter_addresses(config) == []
    end

    # sabotage: envelope/3 took a missing `document` param as
    # "placement_counter" -> the processor shape's send was delivered
    # rather than refused by `document`, red; restored, green.
    test "refuses a malformed envelope by the same reason and row the executor seam writes" do
      config = config("plain_join")
      sender = sender(config)

      assert perform_immediate(config, send_effect(%{"key" => "home_top"}), sender) ==
               {:error, {:send_refused, :document}}

      assert %Ledger{
               binding_id: "execution",
               scope: @scope,
               outcome: "send_refused",
               reason: "document",
               key: nil,
               execution_id: nil
             } = List.last(ledger(config))
    end
  end

  describe "the reserved name at configuration time" do
    # sabotage: route_adapters/1 dropped its reserved-name check -> a host
    # registered a transport under the name a chart writes for the
    # execution target, red; restored, green.
    test "refuses a route registered under the reserved name" do
      assert Config.new(
               repo: TestRepo,
               delivery: StatifierRouter.RecordingDelivery,
               route_adapters: %{"execution" => {RecordingRoute, %{pid: self()}}}
             ) == {:error, {:reserved_route, "execution"}}
    end

    # sabotage: refuse_reserved_id/1 compared the binding's document rather
    # than its id -> a binding under the reserved id wrote ledger rows a
    # reader cannot tell from an execution-to-execution send's, red;
    # restored, green.
    test "refuses a binding whose id is the reserved name" do
      assert Config.new(
               repo: TestRepo,
               delivery: StatifierRouter.RecordingDelivery,
               bindings: [%{impression_binding() | id: "execution"}]
             ) == {:error, {:reserved_binding_id, "execution"}}
    end
  end

  # -- fixtures --------------------------------------------------------

  defp machines do
    for {document, source} <- @documents, into: %{} do
      {:ok, machine} = Statifier.compile(source)
      {document, machine}
    end
  end

  defp impression_binding(document \\ "plain_join") do
    %{
      id: "impressions_to_join",
      source: "ad_events",
      match: "event.kind == 'impression'",
      key: "event.impression_id",
      document: document,
      event: "impression",
      data: ["impression_id"]
    }
  end

  # The host's shape: the handler is the executor, so a `<send>` of the
  # registered type reaches this package from inside the delivery.
  defp config(document, opts \\ []) do
    machines = machines()
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)

    {:ok, static} =
      Static.new(for {name, machine} <- machines, into: %{}, do: {{@scope, name}, machine})

    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})
    pid = self()

    {:ok, config} =
      Config.new(
        repo: TestRepo,
        store: store,
        executor: fn _effect, _context -> :ok end,
        resolver: static,
        chart_resolver: fn content_hash -> Map.fetch(by_hash, content_hash) end,
        bindings: [impression_binding(document)],
        send_type: @type_string,
        timer_queue: Keyword.get(opts, :timer_queue),
        processor_scope: Keyword.get(opts, :processor_scope)
      )

    executor = fn effect, context ->
      send(pid, {:effect, effect})
      answer = SendHandler.handle_effect(config, effect, context)
      send(pid, {:handled, answer})
      answer
    end

    %{config | executor: executor}
  end

  # The same configuration over LedgerFailingRepo, with the executor
  # rebuilt around it so the handler writes through that repo too.
  defp failing_ledger(config) do
    pid = self()
    failing = %{config | repo: StatifierRouter.LedgerFailingRepo}

    executor = fn effect, context ->
      answer = SendHandler.handle_effect(failing, effect, context)
      send(pid, {:handled, answer})
      answer
    end

    %{failing | executor: executor}
  end

  defp impression do
    %{
      scope: @scope,
      message_id: "ad_events/3/1042",
      source: "ad_events",
      data: %{"kind" => "impression", "impression_id" => "imp_7f3a"}
    }
  end

  # One sender execution of the configuration's document, with the address
  # row every send below is read through.
  defp sender(config) do
    {:ok, [{:created_and_delivered, _binding, sender}]} =
      StatifierRouter.route(config, impression(), now: @now)

    sender
  end

  defp send_effect(data, opts \\ []) do
    struct!(
      %Send{
        event: "pair.joined",
        target: "execution",
        type: @type_string,
        data: data,
        send_id: "send_1",
        c_index: 3,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        round: 0,
        ordinal: 1
      },
      opts
    )
  end

  # The send-processor shape end to end: deliver/3 plans under the session
  # id, and perform/2 runs with the configuration installed in this
  # process, as a host's session would.
  defp perform_immediate(config, effect, session_id) do
    on_exit(&SendHandler.delete_config/0)
    event = SendEvent.build(effect, session_id)

    assert {:ok, [{:handler, SendHandler, payload}]} =
             SendHandler.deliver(effect, event, %{session_id: session_id})

    :ok = SendHandler.put_config(config)
    SendHandler.perform(payload, %{session_id: session_id})
  end

  defp delayed_effect do
    %SendDelayed{
      event: "pair.joined",
      target: "execution",
      type: @type_string,
      data: %{"document" => "placement_counter", "key" => "home_top"},
      send_id: "send_1",
      delay_ms: 1_000,
      c_index: 3,
      owner: nil,
      macrostep: 1,
      microstep: 0,
      round: 0,
      ordinal: 1
    }
  end

  defp seam(execution_id), do: %{execution_id: execution_id, content_hash: "sha_1"}

  defp ledger(config),
    do: TestRepo.all(from(l in Config.queryable(config, Ledger), order_by: l.id))

  defp addresses(config, document) do
    TestRepo.all(
      from(a in Config.queryable(config, Address), where: a.document == ^document, order_by: a.id)
    )
  end

  defp counter_addresses(config), do: addresses(config, "placement_counter")

  defp dedupe_rows(config) do
    TestRepo.all(
      from(d in Config.queryable(config, StatifierRouter.Schema.Dedupe),
        order_by: d.id,
        select: d.binding_id
      )
    )
  end
end
