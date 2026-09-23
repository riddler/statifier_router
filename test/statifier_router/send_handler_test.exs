defmodule StatifierRouter.SendHandlerTest do
  use ExUnit.Case, async: true, group: :database

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Machine
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.AddressReadFailingRepo
  alias StatifierRouter.Config
  alias StatifierRouter.DeliveryFixtures
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.RecordingTimerQueue
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.SavepointFailingRepo
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  @now ~U[2026-09-21 08:00:00.000000Z]
  @type_string "myapp:sink"
  @other_type "myapp:audit"
  @scope "7c1e"

  # The impression-and-click join's outbound half (ADR-0005's example).
  # `waiting` logs the handler's own `_ioprocessors` entry on entry, which
  # only exists when the send-types snapshot reached the create inside
  # `initialize:`; `shown` sends to the route on entry.
  @sink """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <onentry><log label="ioproc" expr="_ioprocessors['myapp:sink']"/></onentry>
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <onentry>
        <send type="myapp:sink" target="joined_records" event="joined"/>
      </onentry>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  defp adapters(pid) do
    %{
      "joined_records" => {RecordingRoute, %{pid: pid, sink: "joined_records"}},
      "dead_letter" => {RecordingRoute, %{pid: pid, sink: "dead_letter"}}
    }
  end

  # A configuration with the registry and the handler's type, over the
  # recording delivery: nothing here touches the database.
  defp handler_config(opts \\ []) do
    {:ok, config} =
      [
        repo: TestRepo,
        delivery: RecordingDelivery,
        route_adapters: adapters(self()),
        send_type: @type_string
      ]
      |> Keyword.merge(opts)
      |> Config.new()

    config
  end

  # The full delivery over the sink chart, with the handler wired in as
  # the executor: the shape a host builds.
  defp sink_config(opts \\ []) do
    {:ok, machine} = Statifier.compile(@sink)
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)
    {:ok, static} = Static.new(%{{@scope, "sink_join"} => machine})
    content_hash = Machine.identity(machine).content_hash
    pid = self()

    {:ok, config} =
      [
        repo: TestRepo,
        store: store,
        # Replaced below: the real executor closes over the resolved
        # configuration, which does not exist until new/1 has answered.
        executor: fn _effect, _context -> :ok end,
        resolver: static,
        chart_resolver: fn ^content_hash -> {:ok, machine} end,
        bindings: Enum.map(DeliveryFixtures.bindings(), &Map.put(&1, :document, "sink_join")),
        route_adapters: adapters(pid),
        send_type: @type_string
      ]
      |> Keyword.merge(opts)
      |> Config.new()

    executor = fn effect, context ->
      send(pid, {:effect, effect})
      SendHandler.handle_effect(config, effect, context)
    end

    %{config | executor: executor}
  end

  defp send_effect(opts \\ []) do
    struct!(
      %Send{
        event: "joined",
        target: "joined_records",
        type: @type_string,
        data: %{},
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

  defp delayed_effect(opts \\ []) do
    struct!(
      %SendDelayed{
        event: "timeout",
        target: "joined_records",
        type: @type_string,
        data: %{},
        send_id: "send_1",
        delay_ms: 5_000,
        c_index: 4,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        round: 0,
        ordinal: 2
      },
      opts
    )
  end

  defp seam(execution_id), do: %{execution_id: execution_id, content_hash: "sha_1"}

  # A staging scope pointing joined_records at another sink; dead_letter
  # is overridden by no scope.
  @staging %{"staging" => %{"joined_records" => %{sink: "staging_sink"}}}

  describe "the send-processor shape" do
    setup do
      on_exit(&SendHandler.delete_config/0)
      :ok
    end

    # sabotage: deliver/3 called the adapter itself and returned {:ok, []}
    # -> the adapter was reached with no instruction planned and the
    # perform assertion found nothing, red; restored, green.
    test "plans one handler instruction and performs it against the route" do
      effect = send_effect()
      event = SendEvent.build(effect, "session_1")

      assert {:ok, [{:handler, SendHandler, payload}]} =
               SendHandler.deliver(effect, event, %{session_id: "session_1"})

      # deliver/3 is pure: no process, no clock, no I/O, so nothing has
      # reached the adapter yet.
      refute_received {:routed, _config, _event, _key}

      :ok = SendHandler.put_config(handler_config())
      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok

      assert_received {:routed, %{sink: "joined_records"}, ^event, {"session_1", position, 1}}

      assert position == %{
               send_id: "send_1",
               macrostep: 1,
               microstep: 0,
               round: 0,
               c_index: 3,
               owner: nil
             }
    end

    # sabotage: perform/2's {:send_delayed, ...} arm answered :ok without
    # calling enqueue/4 -> no row was written on this shape, red;
    # restored, green.
    test "records a delayed send on the timer queue as one row under the composed key" do
      effect = delayed_effect()
      event = SendEvent.build(effect, "session_1")

      assert {:ok, [{:handler, SendHandler, payload}]} =
               SendHandler.deliver(effect, event, %{session_id: "session_1"})

      # deliver/3 is pure: planning a delayed send writes no row.
      assert RecordingTimerQueue.entries() == []

      :ok = SendHandler.put_config(handler_config(timer_queue: {RecordingTimerQueue, %{}}))
      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok

      assert [entry] = RecordingTimerQueue.entries()
      assert [^entry] = RecordingTimerQueue.entries("session_1", "send_1")

      assert entry == %{
               scope: "session_1",
               send_id: "send_1",
               route: "joined_records",
               config: %{pid: self(), sink: "joined_records"},
               event: event,
               key:
                 {"session_1",
                  %{
                    send_id: "send_1",
                    macrostep: 1,
                    microstep: 0,
                    round: 0,
                    c_index: 4,
                    owner: nil
                  }, 2},
               delay_ms: 5_000
             }

      # Recorded, not sent: nothing reaches the route until the host fires
      # the row.
      refute_received {:routed, _config, _event, _key}
    end

    # perform/2 MAY be called more than once for one send. The repeat
    # carries the same composed key, and it is the queue's dedup on that
    # key (the schedule/2 callback's obligation, honoured by
    # RecordingTimerQueue) that adds no second row; this handler hands the
    # queue the same key both times. sabotage (the handler's half):
    # perform/2 handed the queue a fresh ordinal on each call -> two rows,
    # red; restored, green. sabotage (the queue's half):
    # RecordingTimerQueue.schedule/2 appended without checking the key ->
    # two rows, red; restored, green.
    test "a redelivered identical delayed send lands no second row" do
      effect = delayed_effect()
      event = SendEvent.build(effect, "session_1")

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: "session_1"})

      :ok = SendHandler.put_config(handler_config(timer_queue: {RecordingTimerQueue, %{}}))
      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok
      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok

      assert [_one] = RecordingTimerQueue.entries()
    end

    # sabotage: perform/2 handed the queue the planned key with its scope
    # half replaced by a constant -> the row differed from the executor
    # seam's, red; restored, green.
    test "records the same row the executor seam records for the same scope" do
      effect = delayed_effect()
      event = SendEvent.build(effect, "ex_1")
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})

      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_1")) == :ok
      assert [seam_entry] = RecordingTimerQueue.entries("ex_1", "send_1")
      assert {:ok, 1} = RecordingTimerQueue.cancel(%{}, "ex_1", "send_1")

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: "ex_1"})

      :ok = SendHandler.put_config(config)
      assert SendHandler.perform(payload, %{session_id: "ex_1"}) == :ok

      assert [^seam_entry] = RecordingTimerQueue.entries("ex_1", "send_1")
    end

    # sabotage: the %Config{timer_queue: nil} clause of schedule/5
    # answered :ok -> a delayed send with nowhere durable to go was
    # dropped silently on this shape too, red; restored, green.
    test "refuses a delayed send when the host registered no queue" do
      effect = delayed_effect()
      event = SendEvent.build(effect, "session_1")

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: "session_1"})

      :ok = SendHandler.put_config(handler_config())

      assert SendHandler.perform(payload, %{session_id: "session_1"}) ==
               {:error, {:no_timer_queue, "send_1"}}
    end

    # sabotage: perform/2 answered :ok for an unregistered route -> the
    # miss the host reports through failed_send/3 disappeared, red;
    # restored, green.
    test "answers a miss with the error the host reports through failed_send/3" do
      # The refusal looks for the sender's address row before it records
      # anything, so this shape reaches the database even though a session
      # id has no such row and no row is written.
      :ok = Sandbox.checkout(TestRepo)
      effect = send_effect(target: "audit_log")
      event = SendEvent.build(effect, "session_1")

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: "session_1"})

      :ok = SendHandler.put_config(handler_config())

      assert SendHandler.perform(payload, %{session_id: "session_1"}) ==
               {:error, {:unregistered_route, "audit_log"}}

      refute_received {:routed, _config, _event, _key}
    end

    # sabotage: fetch_config/0 answered {:ok, %Config{}} for an empty
    # process -> perform/2 raised instead of refusing, red; restored,
    # green.
    test "refuses when the host installed no configuration in this process" do
      effect = send_effect()
      event = SendEvent.build(effect, "session_1")

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: "session_1"})

      assert SendHandler.perform(payload, %{session_id: "session_1"}) ==
               {:error, {:no_config, SendHandler}}
    end

    # sabotage: cancel/2 returned {:ok, []} -> the instruction the session
    # routes back to perform/2 was never planned, red; restored, green.
    # sabotage: perform/2's {:cancel, ...} arm answered :ok without calling
    # dequeue/3 -> the row stood after the cancel, red; restored, green.
    test "plans a cancel and performs it against the queue, in its own session only" do
      :ok = SendHandler.put_config(handler_config(timer_queue: {RecordingTimerQueue, %{}}))
      effect = delayed_effect()

      for session_id <- ["session_1", "session_2"] do
        {:ok, [{:handler, SendHandler, payload}]} =
          SendHandler.deliver(effect, SendEvent.build(effect, session_id), %{
            session_id: session_id
          })

        assert SendHandler.perform(payload, %{session_id: session_id}) == :ok
      end

      cancel = %Cancel{send_id: "send_1", macrostep: 2, microstep: 0, round: 0, ordinal: 2}

      assert {:ok, [{:handler, SendHandler, payload}]} =
               SendHandler.cancel(cancel, %{session_id: "session_1"})

      # cancel/2 is pure: planning the cancel deletes nothing.
      assert [_row] = RecordingTimerQueue.entries("session_1", "send_1")

      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok
      assert RecordingTimerQueue.entries("session_1", "send_1") == []
      assert [%{scope: "session_2"}] = RecordingTimerQueue.entries("session_2", "send_1")

      # A cancel for a send already gone is a no-op, not an error.
      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok
    end

    # sabotage: perform/2's {:cancel, ...} arm, and separately its
    # {:send_delayed, ...} arm, answered :ok for a missing configuration ->
    # the refusal disappeared, red each time; restored, green.
    test "refuses a delayed send and a cancel when the host installed no configuration" do
      effect = delayed_effect()

      {:ok, [{:handler, SendHandler, delayed}]} =
        SendHandler.deliver(effect, SendEvent.build(effect, "session_1"), %{
          session_id: "session_1"
        })

      cancel = %Cancel{send_id: "send_1", macrostep: 2, microstep: 0, round: 0, ordinal: 2}

      {:ok, [{:handler, SendHandler, cancelled}]} =
        SendHandler.cancel(cancel, %{session_id: "session_1"})

      assert SendHandler.perform(delayed, %{session_id: "session_1"}) ==
               {:error, {:no_config, SendHandler}}

      assert SendHandler.perform(cancelled, %{session_id: "session_1"}) ==
               {:error, {:no_config, SendHandler}}
    end

    # sabotage: resolve/2 answered Config.route/3's result without asking
    # whether a scope was in reach -> perform/2 sent to the registered
    # sink with no error, red; restored, green.
    test "refuses a send to an overridden route, this shape having no delivery scope" do
      effect = send_effect()

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, SendEvent.build(effect, "session_1"), %{
          session_id: "session_1"
        })

      :ok = SendHandler.put_config(handler_config(route_overrides: @staging))

      assert SendHandler.perform(payload, %{session_id: "session_1"}) ==
               {:error, {:no_delivery_scope, "joined_records"}}

      refute_received {:routed, _config, _event, _key}
    end

    # sabotage: perform/2's {:send_delayed, ...} arm called enqueue/4
    # inside in_route/2 -> the queue saw a sending execution on a shape
    # with no delivery transaction open, red; restored, green.
    test "marks nothing while the queue runs on this shape" do
      pid = self()
      observe = fn call -> send(pid, {:queue, call, SendHandler.sending_execution()}) end
      effect = delayed_effect()

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, SendEvent.build(effect, "session_1"), %{
          session_id: "session_1"
        })

      :ok =
        SendHandler.put_config(
          handler_config(timer_queue: {RecordingTimerQueue, %{observe: observe}})
        )

      assert SendHandler.perform(payload, %{session_id: "session_1"}) == :ok
      assert_received {:queue, :schedule, nil}
    end

    # sabotage: ioprocessors_entry/1 returned %{} -> spec 5.10's entry
    # carried no value for the registered type, red; restored, green.
    test "answers spec 5.10's entry for the type it is registered under" do
      assert SendHandler.ioprocessors_entry(@type_string) == %{"location" => @type_string}
    end
  end

  describe "the executor seam" do
    # sabotage: hand_off/3 built the event with a constant session id ->
    # the two shapes' events differed in origin, red; restored, green.
    test "hands the adapter the same event and the same key as the send-processor shape" do
      effect = send_effect()
      scope = "ex_9k2q"
      config = handler_config()

      # The send-processor shape, whose scope half is the session id.
      event = SendEvent.build(effect, scope)

      {:ok, [{:handler, SendHandler, payload}]} =
        SendHandler.deliver(effect, event, %{session_id: scope})

      :ok = SendHandler.put_config(config)
      assert SendHandler.perform(payload, %{session_id: scope}) == :ok
      on_exit(&SendHandler.delete_config/0)
      assert_received {:routed, _config, processor_event, processor_key}

      # The process-less shape, whose scope half is the execution id.
      assert SendHandler.handle_effect(config, {:send, effect}, seam(scope)) == :ok
      assert_received {:routed, _config, seam_event, seam_key}

      assert seam_event == processor_event
      assert seam_key == processor_key
    end

    # sabotage: mine?/2 answered true for every effect -> a send of
    # another host's type reached this package's registry, red; restored,
    # green.
    test "ignores an effect of another type, and every effect that is not a send" do
      config = handler_config()

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(type: @other_type)},
               seam("ex_1")
             ) == :ok

      assert SendHandler.handle_effect(
               config,
               {:log, %Log{label: "shown", macrostep: 1, microstep: 0, round: 0}},
               seam("ex_1")
             ) == :ok

      refute_received {:routed, _config, _event, _key}
    end

    # sabotage: Config.route/3 was called with a nil scope from the seam
    # -> the override never applied and the adapter saw the registered
    # configuration, red; restored, green.
    test "applies the delivery's scope override to the configuration the adapter sees" do
      config =
        handler_config(
          route_overrides: %{"staging" => %{"joined_records" => %{sink: "staging_sink"}}}
        )

      :ok = SendHandler.put_delivery_scope("staging")
      on_exit(&SendHandler.delete_delivery_scope/0)

      assert SendHandler.handle_effect(config, {:send, send_effect()}, seam("ex_1")) == :ok
      assert_received {:routed, %{sink: "staging_sink"}, _event, _key}
    end

    # sabotage: refusal/3 answered :ok -> the unregistered route was
    # swallowed and nothing reached the chart, red; restored, green.
    test "refuses a target naming no registered route" do
      # Same reason as the send-processor shape's miss: the refusal reads
      # the sender's address row, and "ex_1" has none, so it is reported
      # and not recorded.
      :ok = Sandbox.checkout(TestRepo)
      config = handler_config()

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(target: "audit_log")},
               seam("ex_1")
             ) == {:error, {:unregistered_route, "audit_log"}}

      assert DeliveryFixtures.ledger(config) == []
    end

    # The third exit of the refusal's savepoint bracket, and the one that
    # can invert it: a savepoint statement that raises AFTER the insert
    # has already landed. SavepointFailingRepo raises on the release and
    # on the rollback, leaving the insert itself untouched.
    #
    # sabotage: RELEASE SAVEPOINT moved back inside insert_guarded/2's
    # `try` (the shape before this cure) -> the rescue fired on the
    # release and issued ROLLBACK TO SAVEPOINT, whose own raise escaped
    # handle_effect/3 and took the sender's step with it, red; restored,
    # green.
    test "a savepoint statement that raises after the insert does not reach the sender" do
      :ok = Sandbox.checkout(TestRepo)
      config = handler_config()

      TestRepo.insert!(
        Config.put_meta(config, %Address{
          scope: @scope,
          document: "sink_join",
          key: "ad_events/3/2201",
          execution_id: "ex_2",
          inserted_at: @now
        })
      )

      assert SendHandler.handle_effect(
               %{config | repo: SavepointFailingRepo},
               {:send, send_effect(target: "audit_log")},
               seam("ex_2")
             ) == {:error, {:unregistered_route, "audit_log"}}

      # The row the insert wrote is still there: a release that cannot
      # run does not roll back what already landed.
      assert [%Ledger{outcome: "send_refused", reason: "route", scope: @scope}] =
               DeliveryFixtures.ledger(config)
    end

    # The composed key written out, every interior component pinned. Each
    # component carries a value no other component carries, so a message
    # id that writes any two of them in each other's place is a different
    # string from the one below.
    #
    # sabotage: message_id/1 listed position.microstep before
    # position.macrostep -> the id read "ex_2/send_4/7/5/..." as
    # "ex_2/send_4/5/7/...", red; restored, green.
    test "writes the composed key into the refusal row's message id in the record's order" do
      :ok = Sandbox.checkout(TestRepo)
      config = handler_config()

      TestRepo.insert!(
        Config.put_meta(config, %Address{
          scope: @scope,
          document: "sink_join",
          key: "ad_events/3/2201",
          execution_id: "ex_2",
          inserted_at: @now
        })
      )

      effect =
        send_effect(
          target: "audit_log",
          send_id: "send_4",
          macrostep: 7,
          microstep: 5,
          round: 3,
          c_index: 11,
          owner: {:onentry, 2, 9},
          ordinal: 13
        )

      assert SendHandler.handle_effect(config, {:send, effect}, seam("ex_2")) ==
               {:error, {:unregistered_route, "audit_log"}}

      # The sender's execution id, then the send's send_id, macrostep,
      # microstep, round, c_index and owner, then the ordinal.
      assert [%Ledger{message_id: "ex_2/send_4/7/5/3/11/{:onentry, 2, 9}/13"}] =
               DeliveryFixtures.ledger(config)
    end

    # sabotage: in_route/2 deleted the key before calling the fun ->
    # sending_execution/0 was nil inside the adapter, red; restored,
    # green.
    test "names the sending execution while a route runs, and only then" do
      pid = self()

      config =
        handler_config(
          route_adapters: %{
            "joined_records" =>
              {RecordingRoute,
               %{
                 pid: pid,
                 answer: fn ->
                   send(pid, {:sending, SendHandler.sending_execution()})
                   :ok
                 end
               }}
          }
        )

      assert SendHandler.sending_execution() == nil
      assert SendHandler.handle_effect(config, {:send, send_effect()}, seam("ex_1")) == :ok
      assert_received {:sending, "ex_1"}
      assert SendHandler.sending_execution() == nil
    end
  end

  describe "the scope a route is resolved in" do
    # sabotage: resolve/2 answered Config.route/3's result without asking
    # whether a scope was in reach -> the send reached the registered
    # sink with no error, red; restored, green.
    test "refuses a send to an overridden route when no delivery scope is in reach" do
      config = handler_config(route_overrides: @staging)

      assert SendHandler.handle_effect(config, {:send, send_effect()}, seam("ex_1")) ==
               {:error, {:no_delivery_scope, "joined_records"}}

      refute_received {:routed, _config, _event, _key}
    end

    # sabotage: unscoped/3 refused whenever :route_overrides was non-empty
    # -> dead_letter, which no scope overrides, was refused too, red;
    # restored, green. sabotage: unscoped/3 counted an empty override map
    # as an override -> the second config's joined_records was refused,
    # red; restored, green.
    test "resolves a route no scope overrides with no delivery scope in reach" do
      config = handler_config(route_overrides: @staging)

      assert SendHandler.handle_effect(
               config,
               {:send, send_effect(target: "dead_letter")},
               seam("ex_1")
             ) == :ok

      assert_received {:routed, %{sink: "dead_letter"}, _event, _key}

      config = handler_config(route_overrides: %{"staging" => %{"joined_records" => %{}}})
      assert SendHandler.handle_effect(config, {:send, send_effect()}, seam("ex_1")) == :ok
      assert_received {:routed, %{sink: "joined_records"}, _event, _key}
    end

    # sabotage: enqueue/4 resolved through Config.route/3 directly -> the
    # delayed send was queued under the registered configuration, red;
    # restored, green.
    test "refuses a delayed send to an overridden route when no delivery scope is in reach" do
      config = handler_config(route_overrides: @staging, timer_queue: {RecordingTimerQueue, %{}})

      assert SendHandler.handle_effect(config, {:send_delayed, delayed_effect()}, seam("ex_1")) ==
               {:error, {:no_delivery_scope, "joined_records"}}

      assert RecordingTimerQueue.entries() == []
    end
  end

  describe "the durable timer queue" do
    # sabotage: schedule/5 wrote the entry without the route name -> a
    # cancel, which carries no target, had nothing to fire against, red;
    # restored, green.
    test "records a delayed send under the cancellation key, with the route it named" do
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})
      effect = delayed_effect()

      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_1")) == :ok

      assert [entry] = RecordingTimerQueue.entries("ex_1", "send_1")
      assert entry.route == "joined_records"
      assert entry.delay_ms == 5_000
      assert entry.config == %{pid: self(), sink: "joined_records"}
      assert entry.event == SendEvent.build(effect, "ex_1")
      # The dedup key rides beside the row; it is not the key the row is
      # stored under.
      assert entry.key ==
               {"ex_1",
                %{
                  send_id: "send_1",
                  macrostep: 1,
                  microstep: 0,
                  round: 0,
                  c_index: 4,
                  owner: nil
                }, 2}
    end

    # THE two-keys pin. sabotage: dequeue/3 passed "ex_2" to the queue in
    # place of the seam's own execution id -> the cancel run in ex_1 left
    # ex_1's timer standing and took ex_2's instead, red; restored, green.
    # A queue keyed on the send id alone fails this test the same way,
    # which is the defect the record names.
    test "a cancel in one execution leaves another execution's timer standing under the same send id" do
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})
      effect = delayed_effect()

      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_1")) == :ok
      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_2")) == :ok

      cancel = %Cancel{send_id: "send_1", macrostep: 2, microstep: 0, round: 0, ordinal: 3}
      assert SendHandler.handle_effect(config, {:cancel, cancel}, seam("ex_1")) == :ok

      assert RecordingTimerQueue.entries("ex_1", "send_1") == []
      assert [%{scope: "ex_2"}] = RecordingTimerQueue.entries("ex_2", "send_1")
    end

    # The queue's at-most-once on the dedup key (the schedule/2 callback's
    # obligation), driven through handle_effect/3 at the executor seam: the
    # same delayed send handed over twice is one row. sabotage:
    # RecordingTimerQueue.schedule/2 appended without checking the key -> two
    # rows, red; restored, green.
    test "the same delayed send scheduled twice is one row under its dedup key" do
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})
      effect = delayed_effect()

      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_1")) == :ok
      assert SendHandler.handle_effect(config, {:send_delayed, effect}, seam("ex_1")) == :ok

      assert [_one] = RecordingTimerQueue.entries("ex_1", "send_1")
    end

    # Spec 6.3 cancels every delayed send under an id, so one cancel may
    # delete more than one row. Driven through handle_effect/3's cancel arm
    # at the executor seam, which calls the TimerQueue's cancel/3 (not
    # SendHandler.cancel/2, the send-processor shape's planning callback).
    # sabotage: dequeue/3 answered {:error, :ambiguous_cancel} for a count
    # above one -> the cancel failed the step, red; restored, green.
    test "one cancel deletes every row in its scope under the send id" do
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})
      first = delayed_effect()
      second = %{first | macrostep: 2, ordinal: 5}

      assert SendHandler.handle_effect(config, {:send_delayed, first}, seam("ex_1")) == :ok
      assert SendHandler.handle_effect(config, {:send_delayed, second}, seam("ex_1")) == :ok
      assert SendHandler.handle_effect(config, {:send_delayed, first}, seam("ex_2")) == :ok
      assert [_first, _second] = RecordingTimerQueue.entries("ex_1", "send_1")

      cancel = %Cancel{send_id: "send_1", macrostep: 3, microstep: 0, round: 0, ordinal: 1}
      assert SendHandler.handle_effect(config, {:cancel, cancel}, seam("ex_1")) == :ok

      assert RecordingTimerQueue.entries("ex_1", "send_1") == []
      assert [%{scope: "ex_2"}] = RecordingTimerQueue.entries("ex_2", "send_1")
    end

    # The TimerQueue moduledoc's "Firing a row" recipe, run as written: a
    # host fires a queued row through Config.route/3 and the route's own
    # deliver/3, with nothing outside the public surface. sabotage:
    # schedule/5 wrote the entry's route as the send's event name in place
    # of its target -> Config.route/3 answered :error for the row, red;
    # restored, green.
    test "a host fires a queued row with the route name, config, event and key it carries" do
      config = handler_config(timer_queue: {RecordingTimerQueue, %{}})

      assert SendHandler.handle_effect(config, {:send_delayed, delayed_effect()}, seam("ex_1")) ==
               :ok

      assert [entry] = RecordingTimerQueue.entries("ex_1", "send_1")

      assert {:ok, {module, _registered}} = Config.route(config, nil, entry.route)
      assert module.deliver(entry.config, entry.event, entry.key) == :ok

      assert_received {:routed, %{sink: "joined_records"}, event, key}
      assert event == entry.event
      assert key == entry.key
    end

    # sabotage: dequeue/3's {:ok, _deleted} clause answered {:error, ...}
    # for a zero count -> a cancel matching nothing failed the step, red;
    # restored, green.
    test "a cancel that matches nothing is a no-op, and a host with no queue has nothing to cancel" do
      cancel = %Cancel{send_id: "send_9", macrostep: 2, microstep: 0, round: 0, ordinal: 3}

      assert SendHandler.handle_effect(
               handler_config(timer_queue: {RecordingTimerQueue, %{}}),
               {:cancel, cancel},
               seam("ex_1")
             ) == :ok

      assert SendHandler.handle_effect(handler_config(), {:cancel, cancel}, seam("ex_1")) == :ok
    end

    # sabotage: handle_effect/3's {:send_delayed, ...} arm, and separately
    # its {:cancel, ...} arm, called the queue outside in_route/2 ->
    # sending_execution/0 was nil inside the queue, red each time;
    # restored, green.
    test "names the sending execution while the queue runs, and only then" do
      pid = self()
      observe = fn call -> send(pid, {:queue, call, SendHandler.sending_execution()}) end
      config = handler_config(timer_queue: {RecordingTimerQueue, %{observe: observe}})

      assert SendHandler.handle_effect(config, {:send_delayed, delayed_effect()}, seam("ex_1")) ==
               :ok

      assert_received {:queue, :schedule, "ex_1"}
      assert SendHandler.sending_execution() == nil

      cancel = %Cancel{send_id: "send_1", macrostep: 2, microstep: 0, round: 0, ordinal: 3}
      assert SendHandler.handle_effect(config, {:cancel, cancel}, seam("ex_1")) == :ok
      assert_received {:queue, :cancel, "ex_1"}
      assert SendHandler.sending_execution() == nil
    end

    # sabotage: the %Config{timer_queue: nil} clause of schedule/5
    # answered :ok -> a delayed send with nowhere durable to go was
    # dropped silently, red; restored, green.
    test "refuses a delayed send when the host registered no queue" do
      assert SendHandler.handle_effect(
               handler_config(),
               {:send_delayed, delayed_effect()},
               seam("ex_1")
             ) == {:error, {:no_timer_queue, "send_1"}}
    end
  end

  describe "a durable execution through Delivery" do
    setup do
      :ok = Sandbox.checkout(TestRepo)
      :ok
    end

    # THE create/4 initialize: pin. sabotage: Delivery.create_options/1
    # passed the snapshot beside the machine instead of inside
    # initialize: -> `_ioprocessors` carried no entry for the registered
    # type and the logged value came back nil, red; restored, green.
    test "carries the send-types snapshot into the created execution's _ioprocessors" do
      config = sink_config()

      assert {:ok, [{:created_and_delivered, _binding, _execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      assert_received {:effect, {:log, %Log{label: "ioproc", value: value}}}
      assert value == %{"location" => @type_string}
    end

    # sabotage: SendHandler.handle_effect/3's {:send, ...} clause answered
    # :ok without routing -> the chart's send reached no adapter though
    # the execution stepped, red; restored, green.
    test "hands the chart's send to the route with the execution id as the key's scope" do
      config = sink_config()

      assert {:ok, [{:created_and_delivered, _binding, execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      assert_received {:routed, %{sink: "joined_records"}, event,
                       {^execution_id, _position, _ord}}

      assert event.name == "joined"
    end

    # sabotage: SendHandler.refusal/3 raised instead of answering an error
    # -> the delivery rolled back and the step did not commit, red;
    # restored, green.
    # sabotage: insert_refusal/4 answered :ok without inserting -> the
    # ledger held the delivery's row and no send_refused row, red;
    # restored, green.
    test "an unregistered route is reported and recorded, and the step still commits" do
      config = sink_config(route_adapters: %{"dead_letter" => {RecordingRoute, %{pid: self()}}})

      assert {:ok, [{:created_and_delivered, _binding, execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      refute_received {:routed, _config, _event, _key}

      # The step stands: the execution exists and its input log holds the
      # event that fired the refused send.
      assert {:ok, [%{event: %{name: "impression"}}]} =
               StatifierPersistence.Executions.inputs(config.store, execution_id)

      # RF062-R1's row, committed with the step that sent it. The ledger
      # holds it and the delivery that created the sender, one each: the
      # reserved binding id is what tells the two apart.
      {refusals, deliveries} =
        Enum.split_with(DeliveryFixtures.ledger(config), &(&1.binding_id == "execution"))

      assert [%Ledger{outcome: "created_and_delivered", execution_id: ^execution_id}] = deliveries

      assert [
               %Ledger{
                 scope: @scope,
                 outcome: "send_refused",
                 reason: "route",
                 key: nil,
                 execution_id: nil,
                 message_id: message_id
               }
             ] = refusals

      # The message id is ADR-0005, section 4's key written out: the
      # sender's execution id, then the send's send_id, macrostep,
      # microstep, round, c_index and owner, then the ordinal.
      assert [^execution_id, _send_id, _macrostep, _microstep, _round, _c_index, _owner, _ordinal] =
               String.split(message_id, "/")
    end

    # The address-row read the refusal's row needs is made inside the
    # sender's transaction, where a failed SELECT leaves that transaction
    # aborted as a failed insert does. AddressReadFailingRepo makes the
    # read fail in Postgres, for the handler only; the delivery around it
    # runs on the real repo.
    #
    # sabotage: record_refusal/4 read Addresses.by_execution/2 ahead of
    # write_guarded/3 again (the shape before the read moved inside the
    # bracket) -> the failed read raised out of the executor and took the
    # sender's step down, so route/3 raised instead of answering an
    # outcome, red; restored, green.
    test "an address read that fails leaves the sender's step standing and writes no row" do
      pid = self()
      config = sink_config(route_adapters: %{"dead_letter" => {RecordingRoute, %{pid: pid}}})
      failing = %{config | repo: AddressReadFailingRepo}

      config = %{
        config
        | executor: fn effect, context ->
            answer = SendHandler.handle_effect(failing, effect, context)
            send(pid, {:handled, answer})
            answer
          end
      }

      assert {:ok, [{:created_and_delivered, _binding, execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      # The refusal is still reported, whatever the read did.
      assert_received {:handled, {:error, {:unregistered_route, "joined_records"}}}

      assert {:ok, [%{event: %{name: "impression"}}]} =
               Executions.inputs(config.store, execution_id)

      # No refusal row: the read rolled back to its savepoint. The
      # delivery's own row stands.
      assert [%Ledger{outcome: "created_and_delivered", execution_id: ^execution_id}] =
               DeliveryFixtures.ledger(config)
    end

    # The scope a real delivery runs under reaches the handler, so a route
    # some scope overrides resolves in it rather than being refused.
    # sabotage: Delivery's delivered/4 skipped put_delivery_scope/1 -> the
    # handler refused the send as no_delivery_scope and nothing was
    # routed, red; restored, green.
    test "resolves an overridden route in the scope of the delivery that sent it" do
      config =
        sink_config(route_overrides: %{@scope => %{"joined_records" => %{sink: "scoped_sink"}}})

      assert {:ok, [{:created_and_delivered, _binding, _execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      assert_received {:routed, %{sink: "scoped_sink"}, %{name: "joined"}, _key}
    end

    # THE reentrancy pin. sabotage: Delivery.deliver/4's
    # sending_execution/0 check removed -> the route's nested route/3 ran
    # a step from a position the outer step had not written, red;
    # restored, green.
    test "refuses a route that calls back into the sending execution" do
      pid = self()

      reentrant = fn ->
        send(pid, {:reentered, StatifierRouter.route(Process.get(:config), click(), now: @now)})
        :ok
      end

      config =
        sink_config(
          route_adapters: %{
            "joined_records" => {RecordingRoute, %{pid: pid, answer: reentrant}}
          }
        )

      Process.put(:config, config)

      assert {:ok, [{:created_and_delivered, _binding, execution_id}, _]} =
               StatifierRouter.route(config, DeliveryFixtures.impression(), now: @now)

      assert_received {:reentered, {:error, {:reentrant_route, ^execution_id}}}
    end
  end

  defp click, do: DeliveryFixtures.click("ad_events/3/2201")
end
