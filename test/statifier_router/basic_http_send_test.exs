defmodule StatifierRouter.BasicHTTPSendTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Send
  alias Statifier.Machine
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Addresses
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.Delivery
  alias StatifierRouter.Schema.Ledger
  alias StatifierRouter.TestRepo

  # ADR-0002, the Amendment of 2026-10-02: a durable execution's outbound
  # BasicHTTP send is planned at the executor seam and performed after
  # the delivery commits, and a failed POST reaches the execution only
  # through Delivery.deliver_event/4 with create: :never over the row
  # Addresses.by_execution/2 answers. These tests pin that path against
  # the package as it is; they add no behaviour.

  defmodule DepotDown do
    @moduledoc false
    @behaviour Statifier.Send.BasicHTTP.Transport

    # The depot's manifest desk answers every POST 503.
    @impl true
    def post(_url, _headers, _body), do: {:ok, 503}
  end

  @base_url "https://depot.example/scxml"
  @now ~U[2026-10-02 08:00:00.000000Z]

  # The plan the host's job delivers under: a name of its own on the
  # ledger, never `execution` or `basichttp`, and create: :never.
  @plan %{
    id: "basichttp_failure",
    document: "parcel_manifest",
    create: :never,
    dedupe: %{by: :message_id, horizon_ms: 259_200_000}
  }

  # A parcel loaded onto the van tells the depot's manifest desk, and
  # waits on the van. A failed POST returns it to the depot, which
  # finishes the execution.
  @manifest """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
    <state id="at_depot">
      <transition event="loaded" target="on_van"/>
    </state>
    <state id="on_van">
      <onentry>
        <send id="manifest" type="basichttp" target="https://depot.example/manifests" event="parcel.loaded"/>
      </onentry>
      <transition event="delivered" target="doorstep"/>
      <transition event="error.communication" cond="_event.sendid == 'manifest'" target="returned_to_depot"/>
    </state>
    <final id="doorstep"/>
    <final id="returned_to_depot">
      <onentry>
        <log label="returned_to_depot"/>
      </onentry>
    </final>
  </scxml>
  """

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  # The recipe's executor: a BasicHTTP send is planned with deliver/3 and
  # each planned instruction is handed over as the job the host would
  # insert inside the delivery's transaction. Nothing is performed here.
  defp manifest_config(pid) do
    {:ok, machine} = Statifier.compile(@manifest)
    content_hash = Machine.identity(machine).content_hash

    executor = fn
      {:send, %Send{type: "basichttp"} = send}, %{execution_id: execution_id} ->
        ctx = %{session_id: execution_id, opts: [base_url: @base_url, transport: DepotDown]}
        {:ok, instructions} = BasicHTTP.deliver(send, SendEvent.build(send, execution_id), ctx)

        for {:handler, Statifier.Send.BasicHTTP, payload} <- instructions do
          send(pid, {:job, execution_id, send, payload, ctx})
        end

        :ok

      {:log, %Statifier.Effect.Log{label: label}}, _context ->
        send(pid, {:entered, label})
        :ok

      _effect, _context ->
        :ok
    end

    config(pid,
      bindings: parcel_bindings("parcel_manifest"),
      basichttp: [base_url: @base_url, transport: DepotDown],
      executor: executor,
      resolver: fn "7c1e", "parcel_manifest" -> {content_hash, machine} end,
      chart_resolver: fn ^content_hash -> {:ok, machine} end
    )
  end

  # The host's job, after the delivery committed: perform the planned
  # POST, and on a failure deliver error.communication back in.
  defp run_job({:job, execution_id, send, payload, ctx}, config) do
    {:error, reason} = BasicHTTP.perform(payload, ctx)

    case Addresses.by_execution(config, execution_id) do
      nil ->
        {:dead_letter, reason}

      row ->
        event =
          Statifier.Event.external("error.communication",
            sendid: send.send_id,
            data: %{"reason" => inspect(reason)}
          )

        Delivery.deliver_event(config, @plan, row.key, %{
          event: event,
          message_id: job_key(execution_id, send),
          scope: row.scope,
          now: @now
        })
    end
  end

  # The job's key: the send's dedup key, written out.
  defp job_key(execution_id, %Send{} = send) do
    [
      execution_id,
      send.send_id,
      send.macrostep,
      send.microstep,
      send.round,
      send.c_index,
      send.owner,
      send.ordinal
    ]
    |> Enum.map_join("/", fn
      value when is_binary(value) -> value
      value -> inspect(value)
    end)
  end

  defp loaded(config) do
    scan = %{
      parcel_scan("parcel_scans/1/0001", "loaded")
      | data: %{"kind" => "loaded", "parcel_id" => "pcl_4821"}
    }

    assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
             StatifierRouter.route(config, scan, now: @now)

    execution_id
  end

  describe "a failed after-commit send" do
    # sabotage: the private by_mode/4 of StatifierRouter.Delivery made to
    # skip the address lookup for a :never plan -> the delivery answered
    # dropped: no_execution, red; restored, green.
    # sabotage: the private claimed/4 made to step a :duplicate claim as
    # a new one -> the retried job answered dropped: finished, not
    # duplicate, red; restored, green.
    test "re-enters the execution as error.communication through deliver_event/4" do
      config = manifest_config(self())
      execution_id = loaded(config)

      assert_received {:job, ^execution_id, %Send{send_id: "manifest"}, _payload, _ctx} =
                        job

      assert {:ok, %{status: :active}} = Storage.fetch_execution(config.store, execution_id)

      assert run_job(job, config) == {:delivered, "basichttp_failure", execution_id}

      assert inputs(config, execution_id) == [
               {0, "step", "loaded"},
               {1, "step", "error.communication"}
             ]

      assert {:ok, %{status: :completed}} = Storage.fetch_execution(config.store, execution_id)
      assert_received {:entered, "returned_to_depot"}

      {:ok, entries} = Executions.inputs(config.store, execution_id)
      assert %{"reason" => "{:http_status, 503}"} = List.last(entries).event.data

      assert %Ledger{
               binding_id: "basichttp_failure",
               scope: "7c1e",
               outcome: "delivered",
               key: "pcl_4821",
               execution_id: ^execution_id
             } = List.last(ledger(config))

      # The job retried after it delivered: the same key is a duplicate.
      assert run_job(job, config) == {:duplicate, "basichttp_failure"}
      assert length(inputs(config, execution_id)) == 2
    end

    # sabotage: the private finished/6 of StatifierRouter.Delivery made
    # to answer {:delivered, plan.id, execution_id} -> the job's delivery
    # answered delivered, red; restored, green.
    test "reaching a finished execution is dropped as finished, as the plan answers today" do
      config = manifest_config(self())
      execution_id = loaded(config)
      assert_received {:job, ^execution_id, _send, _payload, _ctx} = job

      assert {:ok, [{:no_match, "loaded_scans"}, {:delivered, "delivered_scans", ^execution_id}]} =
               StatifierRouter.route(
                 config,
                 parcel_scan("parcel_scans/1/0002", "delivered"),
                 now: @now
               )

      assert run_job(job, config) == {:dropped, "basichttp_failure", :finished}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]

      assert %Ledger{binding_id: "basichttp_failure", outcome: "dropped: finished"} =
               List.last(ledger(config))
    end
  end
end
