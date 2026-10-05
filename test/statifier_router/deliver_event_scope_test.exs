defmodule StatifierRouter.DeliverEventScopeTest do
  # Not async: the statement capture below attaches to every statement the
  # test repo runs, which only a module that runs alone can read as its
  # own (StatifierRouter.AroundDeliveryTest says the same).
  use ExUnit.Case, async: false

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Machine
  alias StatifierRouter.Addresses
  alias StatifierRouter.Delivery
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo

  # ADR-0002, the Amendment of 2026-10-04: a host that delivers a prebuilt
  # event through Delivery.deliver_event/4 may set `run_in_scope: true` in
  # the envelope, and the step that delivery drives then resolves a route
  # in the envelope's `scope`, as a binding's delivery and the BasicHTTP
  # front do. Without the key the step runs with no scope of its own, and
  # a send to a route some scope overrides is refused as
  # `{:no_delivery_scope, name}`, as in 0.10.0.

  @now ~U[2026-10-04 08:00:00.000000Z]
  @type_string "myapp:notify"
  @scope "7c1e"
  @other_scope "a90f"

  # The host job's plan: a name of its own on the ledger, create: :never.
  @plan %{
    id: "delivery_failure",
    document: "parcel_notice",
    create: :never,
    dedupe: %{by: :message_id, horizon_ms: 259_200_000}
  }

  # A parcel on the van. A failed delivery, which the host's job delivers
  # back in, returns it to the depot and tells the recipient; a delivered
  # scan tells the depot's desk first and the recipient after.
  @notice """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
    <state id="at_depot">
      <transition event="loaded" target="on_van"/>
    </state>
    <state id="on_van">
      <transition event="delivered" target="doorstep"/>
      <transition event="delivery.failed" target="returned_to_depot"/>
    </state>
    <state id="doorstep">
      <onentry>
        <send type="myapp:notify" target="depot_desk" event="parcel.delivered"/>
        <send type="myapp:notify" target="recipient_notices" event="parcel.delivered"/>
      </onentry>
    </state>
    <state id="returned_to_depot">
      <onentry>
        <send type="myapp:notify" target="recipient_notices" event="parcel.returned"/>
      </onentry>
    </state>
  </scxml>
  """

  # Each scope sends the recipient's notices to a sink of its own; the
  # depot's desk is overridden by no scope.
  @overrides %{
    @scope => %{"recipient_notices" => %{sink: "notices_7c1e"}},
    @other_scope => %{"recipient_notices" => %{sink: "notices_a90f"}}
  }

  # The statements a host job issues without the key - its address read,
  # then deliver_event/4 from its begin to its commit - captured by the
  # last test below at the commit before the key existed and normalized by
  # normalize/1: the delivery of delivery.failed to a parcel on the van,
  # whose step's send to an overridden route is refused and re-enters the
  # step as error.communication.
  @unscoped [
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 WHERE (s0.\"execution_id\" = $) ORDER BY s0.\"id\" LIMIT 1",
    "begin",
    "SAVEPOINT sr_execution_target_N",
    "INSERT INTO \"statifier_router_dedupe\" AS s0 (\"binding_id\",\"expires_at\",\"message_id\") VALUES ($,$,$) ON CONFLICT (\"binding_id\",\"message_id\") DO UPDATE SET \"expires_at\" = $ WHERE (s0.\"expires_at\" < $)",
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 WHERE (((s0.\"scope\" = $) AND (s0.\"document\" = $)) AND (s0.\"key\" = $))",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT pg_advisory_xact_lock(hashtextextended($::text, 0))",
    "SELECT s0.\"id\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $) FOR UPDATE",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"seq\", s0.\"input_blob\" FROM \"statifier_inputs\" AS s0 WHERE (s0.\"execution_id\" = $) ORDER BY s0.\"seq\" DESC LIMIT 1",
    "INSERT INTO \"statifier_inputs\" (\"door\",\"execution_id\",\"id\",\"input_blob\",\"inserted_at\",\"seq\",\"updated_at\") VALUES ($,$,$,$,$,$,$)",
    "UPDATE \"statifier_executions\" AS s0 SET \"content_hash\" = $, \"failure\" = $, \"identity_blob\" = $, \"position_blob\" = $, \"status\" = $, \"updated_at\" = $ WHERE (s0.\"execution_id\" = $)",
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"execution_id\",\"inserted_at\",\"key\",\"message_id\",\"outcome\",\"scope\") VALUES ($,$,$,$,$,$,$) RETURNING \"id\"",
    "RELEASE SAVEPOINT sr_execution_target_N",
    "commit"
  ]

  setup do
    :ok = Sandbox.checkout(TestRepo)

    test_pid = self()
    handler = "deliver-event-scope-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:statifier_router, :test_repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:statement, self(), normalize(metadata.query)})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # The host's configuration: the handler wired in as the executor, which
  # reports each effect's answer, and the two routes.
  defp notice_config(pid, depot_desk \\ :ok) do
    {:ok, machine} = Statifier.compile(@notice)
    content_hash = Machine.identity(machine).content_hash

    config =
      config(pid,
        bindings: parcel_bindings("parcel_notice"),
        resolver: fn _scope, "parcel_notice" -> {content_hash, machine} end,
        chart_resolver: fn ^content_hash -> {:ok, machine} end,
        send_type: @type_string,
        route_adapters: %{
          "recipient_notices" => {RecordingRoute, %{pid: pid, sink: "recipient_notices"}},
          "depot_desk" => {RecordingRoute, %{pid: pid, sink: "depot_desk", answer: depot_desk}}
        },
        route_overrides: @overrides
      )

    executor = fn effect, context ->
      answer = SendHandler.handle_effect(config, effect, context)
      send(pid, {:handled, effect, answer})
      answer
    end

    %{config | executor: executor}
  end

  # A parcel loaded onto the van in `scope`: the binding's delivery creates
  # its execution.
  defp loaded(config, scope, message_id) do
    scan = %{parcel_scan(message_id, "loaded") | scope: scope}

    assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
             StatifierRouter.route(config, scan, now: @now)

    execution_id
  end

  # The host's job: delivery.failed back in through deliver_event/4, over
  # the row Addresses.by_execution/2 answers, with `extra` in the envelope.
  defp failed(config, execution_id, extra) do
    row = Addresses.by_execution(config, execution_id)

    envelope =
      Map.merge(
        %{
          event: Statifier.Event.external("delivery.failed"),
          message_id: "delivery_jobs/" <> execution_id,
          scope: row.scope,
          now: @now
        },
        extra
      )

    Delivery.deliver_event(config, %{@plan | document: row.document}, row.key, envelope)
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, pid, query} -> statements([{pid, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp queries(statements, pid), do: for({^pid, query} <- statements, do: query)

  # What may differ between two runs of the same statement is taken out,
  # so two runs compare: the unique integer in a savepoint name, the
  # parameter numbers, and the order Ecto lists an INSERT's columns and an
  # UPDATE's assignments in, which follows the order of a map's keys.
  defp normalize(query) do
    query = Regex.replace(~r/(sr_[a-z_]+?)_\d+/, query, "\\1_N")
    query = Regex.replace(~r/\$\d+/, query, "$")

    query =
      Regex.replace(~r/^(INSERT INTO \S+(?: AS \S+)? )\(([^)]*)\)/, query, fn _, head, columns ->
        head <> "(" <> sorted(columns, ",") <> ")"
      end)

    Regex.replace(~r/^(UPDATE .*? SET )(.*?)( WHERE )/, query, fn _, head, set, where ->
      head <> sorted(set, ", ") <> where
    end)
  end

  defp sorted(list, separator) do
    list
    |> String.split(~r/#{separator}(?=")/)
    |> Enum.sort()
    |> Enum.join(separator)
  end

  describe "a host's deliver_event/4 and a route a scope overrides" do
    # sabotage: SendHandler's private unscoped/3 made to answer the
    # registered route whatever the overrides -> the send was routed to
    # recipient_notices and the handler answered :ok, red; restored, green.
    test "without the key, the step's send to an overridden route is refused" do
      config = notice_config(self())
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      assert failed(config, execution_id, %{}) ==
               {:delivered, "delivery_failure", execution_id}

      assert_received {:handled, {:send, %{target: "recipient_notices"}},
                       {:error, {:no_delivery_scope, "recipient_notices"}}}

      refute_received {:routed, _route_config, _event, _key}

      # The step stands: the refusal did not roll it back.
      assert inputs(config, execution_id) == [
               {0, "step", "loaded"},
               {1, "step", "delivery.failed"}
             ]
    end

    # sabotage: deliver_event/4 made to ignore run_in_scope: true -> the
    # send was refused as no_delivery_scope and nothing was routed, red;
    # restored, green.
    test "with run_in_scope: true, the step's send resolves in the envelope's scope" do
      config = notice_config(self())
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      assert failed(config, execution_id, %{run_in_scope: true}) ==
               {:delivered, "delivery_failure", execution_id}

      assert_received {:routed, %{sink: "notices_7c1e"}, %{name: "parcel.returned"},
                       {^execution_id, _position, _ordinal}}

      assert_received {:handled, {:send, %{target: "recipient_notices"}}, :ok}

      # The scope is the call's alone: nothing is left set behind it.
      assert Process.get({SendHandler, :delivery_scope}) == nil
    end

    # sabotage: deliver_event/4 made to treat run_in_scope: false as true
    # -> the send resolved in 7c1e and was not refused, red; restored,
    # green.
    test "run_in_scope: false answers as the key left out does" do
      config = notice_config(self())
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      assert failed(config, execution_id, %{run_in_scope: false}) ==
               {:delivered, "delivery_failure", execution_id}

      assert queries(statements(), self()) == @unscoped

      assert_received {:handled, {:send, %{target: "recipient_notices"}},
                       {:error, {:no_delivery_scope, "recipient_notices"}}}

      refute_received {:routed, _route_config, _event, _key}
    end

    # sabotage: the raise for a value that is not a boolean removed (any
    # other value read as false) -> deliver_event/4 answered an outcome,
    # red; restored, green.
    test "a value that is not a boolean raises before anything is written" do
      config = notice_config(self())
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      assert_raise ArgumentError, ~r/run_in_scope/, fn ->
        failed(config, execution_id, %{run_in_scope: "yes"})
      end

      # The job's own address read is the only statement: the delivery
      # opened nothing.
      assert queries(statements(), self()) == Enum.take(@unscoped, 1)
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end
  end

  describe "a host's deliver_event/4 inside a sending step" do
    # The depot's desk route, called at the executor seam inside the step
    # a delivered scan drives in 7c1e, delivers delivery.failed to a
    # parcel in a90f with the key set. That nested step resolves its send
    # in a90f; once it returns, the outer step's next send resolves in
    # 7c1e again.
    #
    # sabotage: SendHandler's in_delivery_scope/2 made to delete the scope
    # on its way out instead of putting the earlier one back -> the outer
    # step's second send was refused as no_delivery_scope, red; restored,
    # green.
    test "puts the sending step's scope back when it returns" do
      pid = self()

      depot_desk = fn ->
        config = Process.get(:host_config)
        other = Process.get(:other_execution)
        send(pid, {:nested, failed(config, other, %{run_in_scope: true})})
        :ok
      end

      config = notice_config(pid, depot_desk)
      Process.put(:host_config, config)

      other = loaded(config, @other_scope, "parcel_scans/2/0001")
      Process.put(:other_execution, other)
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      assert {:ok, [_loaded, {:delivered, "delivered_scans", ^execution_id}]} =
               StatifierRouter.route(
                 config,
                 parcel_scan("parcel_scans/1/0002", "delivered"),
                 now: @now
               )

      assert_received {:nested, {:delivered, "delivery_failure", ^other}}

      assert_received {:routed, %{sink: "depot_desk"}, %{name: "parcel.delivered"}, _key}

      assert_received {:routed, %{sink: "notices_a90f"}, %{name: "parcel.returned"},
                       {^other, _position, _ordinal}}

      assert_received {:routed, %{sink: "notices_7c1e"}, %{name: "parcel.delivered"},
                       {^execution_id, _position, _ordinal}}
    end
  end

  describe "without the key" do
    # sabotage: deliver_event/4's unset path made to run one extra
    # statement (a SELECT 1 on the repo) before it settled -> the captured
    # statements differed, red; restored, green.
    test "issues the same statements and answers the same as before the key existed" do
      config = notice_config(self())
      execution_id = loaded(config, @scope, "parcel_scans/1/0001")
      flush()

      me = self()
      answer = failed(config, execution_id, %{})
      seen = queries(statements(), me)

      assert answer == {:delivered, "delivery_failure", execution_id}
      assert seen == @unscoped
    end
  end
end
