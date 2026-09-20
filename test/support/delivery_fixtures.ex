defmodule StatifierRouter.DeliveryFixtures do
  @moduledoc """
  What the `StatifierRouter.Delivery` tests share: the impression-and-click
  bindings, the charts their documents start on, a resolver and a chart
  resolver over those charts, an executor that reports every effect to a
  process, and readers for the rows a delivery leaves. Test-only support
  code, not part of the package's public API.
  """

  import Ecto.Query, only: [from: 2]

  alias Statifier.Machine
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Storage
  alias StatifierRouter.Config
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.Schema.{Address, Ledger}
  alias StatifierRouter.TestPersistence
  alias StatifierRouter.TestRepo

  # An impression waits for its click; the click ends the execution. The
  # impression's state logs on entry, so its step hands the executor one
  # effect.
  @join """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
    <state id="waiting">
      <transition event="impression" target="shown"/>
    </state>
    <state id="shown">
      <onentry><log label="impression_shown"/></onentry>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # One invoke in the initial configuration and one behind the impression:
  # the create path and the step path each enter exactly one of them, so a
  # declared invoke-type snapshot that reaches only one door is visible.
  # The two types are the credit-card domain's authorization and capture,
  # which is where this family's example invoke types come from.
  @invoked """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="opening">
    <state id="opening">
      <invoke type="myapp:authorize"/>
      <transition event="impression" target="billing"/>
    </state>
    <state id="billing">
      <invoke type="myapp:capture"/>
      <transition event="click" target="clicked"/>
    </state>
    <final id="clicked"/>
  </scxml>
  """

  # A chart that is finished as soon as it is initialized.
  @instant """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="done">
    <final id="done"/>
  </scxml>
  """

  @doc "ADR-0001's two bindings, one document, one key."
  @spec bindings() :: [map()]
  def bindings do
    [
      %{
        id: "impressions_to_join",
        source: "ad_events",
        match: "event.kind == 'impression'",
        key: "event.impression_id",
        document: "impression_click_join",
        event: "impression",
        data: ["impression_id", "placement"]
      },
      %{
        id: "clicks_to_join",
        source: "ad_events",
        match: "event.kind == 'click'",
        key: "event.impression_id",
        document: "impression_click_join",
        event: "click",
        data: ["impression_id", "url"]
      }
    ]
  end

  @doc "The compiled charts, by document."
  @spec machines() :: %{String.t() => Machine.t()}
  def machines do
    for {document, source} <- [
          {"impression_click_join", @join},
          {"instant_join", @instant},
          {"invoked_join", @invoked}
        ],
        into: %{} do
      {:ok, machine} = Statifier.compile(source)
      {document, machine}
    end
  end

  @doc """
  A configuration over the default delivery. `opts` override any option;
  the resolver is a `StatifierRouter.Resolver.Static` over `machines/0`
  under the scope `7c1e`, and reports each call to `pid`.
  """
  @spec config(pid(), keyword()) :: Config.t()
  def config(pid, opts \\ []) do
    machines = machines()
    {:ok, store} = Storage.new(Storage.Ecto, persistence: TestPersistence)

    {:ok, static} =
      Static.new(
        for {document, machine} <- machines, into: %{} do
          {{"7c1e", document}, machine}
        end
      )

    resolver = fn scope, document ->
      send(pid, {:resolved, scope, document})
      static.(scope, document)
    end

    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})
    chart_resolver = fn content_hash -> Map.fetch(by_hash, content_hash) end

    {:ok, config} =
      [
        repo: TestRepo,
        store: store,
        executor: executor(pid),
        resolver: resolver,
        chart_resolver: chart_resolver,
        bindings: bindings()
      ]
      |> Keyword.merge(opts)
      |> Config.new()

    config
  end

  @doc "An executor that sends `{:effect, effect}` to `pid` for every effect."
  @spec executor(pid()) :: StatifierPersistence.Executor.t()
  def executor(pid) do
    fn effect, _context ->
      send(pid, {:effect, effect})
      :ok
    end
  end

  @doc "An event for the `ad_events` source under the scope `7c1e`."
  @spec event(String.t(), map()) :: StatifierRouter.source_event()
  def event(message_id, data),
    do: %{scope: "7c1e", message_id: message_id, source: "ad_events", data: data}

  @doc "The impression `ad_events/3/1042` of `imp_7f3a`."
  @spec impression() :: StatifierRouter.source_event()
  def impression do
    event("ad_events/3/1042", %{
      "kind" => "impression",
      "impression_id" => "imp_7f3a",
      "placement" => "sidebar"
    })
  end

  @doc "A click on `imp_7f3a`, under `message_id`."
  @spec click(String.t()) :: StatifierRouter.source_event()
  def click(message_id \\ "ad_events/3/1107") do
    event(message_id, %{
      "kind" => "click",
      "impression_id" => "imp_7f3a",
      "url" => "https://example.com/offer"
    })
  end

  @doc "Every address row under the configuration."
  @spec addresses(Config.t()) :: [Address.t()]
  def addresses(config), do: TestRepo.all(Config.queryable(config, Address))

  @doc "Every ledger row under the configuration, oldest first."
  @spec ledger(Config.t()) :: [Ledger.t()]
  def ledger(config),
    do: TestRepo.all(from(l in Config.queryable(config, Ledger), order_by: l.id))

  @doc "How many execution rows statifier_persistence holds, in every scope."
  @spec executions() :: non_neg_integer()
  def executions, do: TestRepo.aggregate(TestPersistence.Execution, :count)

  @doc "How many input log rows statifier_persistence holds, for every execution."
  @spec input_rows() :: non_neg_integer()
  def input_rows, do: TestRepo.aggregate(TestPersistence.Input, :count)

  @doc "The input log of one execution, as `{seq, door, event name}`."
  @spec inputs(Config.t(), String.t()) :: [{non_neg_integer(), String.t(), String.t()}]
  def inputs(config, execution_id) do
    {:ok, entries} = Executions.inputs(config.store, execution_id)
    Enum.map(entries, &{&1.seq, &1.door, &1.event.name})
  end
end
