defmodule StatifierRouter.BasicHTTPTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Send.Types
  alias StatifierPersistence.Executions
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.BasicHTTP.Front
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Address, Ledger, Location}
  alias StatifierRouter.TestRepo

  doctest StatifierRouter.BasicHTTP.Front

  # ADR-0002, the Amendment of 2026-09-30: a durable execution's BasicHTTP
  # location is a token the router mints beside the address row, and the
  # front delivers a POST at it through the existing delivery path.

  @base_url "https://depot.example/scxml"
  @now ~U[2026-09-30 08:00:00.000000Z]
  @form "application/x-www-form-urlencoded"
  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"

  # A well-formed send key: eight `/`-separated fields.
  @send_key "sess_depot/scan_1/3/1/0/0/onentry.0.0/0"

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  defp basichttp_config(opts \\ []) do
    config(
      self(),
      Keyword.merge([bindings: parcel_bindings(), basichttp: [base_url: @base_url]], opts)
    )
  end

  # A parcel loaded onto the van: the execution the location reaches.
  defp loaded_parcel(config, message_id \\ "parcel_scans/1/0001", parcel_id \\ "pcl_4821") do
    scan = %{
      parcel_scan(message_id, "loaded")
      | data: %{"kind" => "loaded", "parcel_id" => parcel_id}
    }

    assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
             StatifierRouter.route(config, scan, now: @now)

    assert {:ok, location} = BasicHTTP.location(config, execution_id)
    {execution_id, location}
  end

  defp token(location), do: String.replace_prefix(location, @base_url <> "/", "")

  defp post(token, event, overrides \\ %{}) do
    Map.merge(
      %{
        token: token,
        method: "POST",
        content_type: @form,
        body: "_scxmleventname=" <> event,
        query: nil,
        send_key: nil
      },
      overrides
    )
  end

  defp handle(config, request), do: Front.handle(config, request, now: @now)

  describe "the location" do
    # sabotage: locate/3 in StatifierRouter.Delivery made to skip every
    # configuration -> no location row was written and location/2
    # answered {:error, :no_location}, red; restored, green.
    # sabotage: mint_token/0 made to pad its base64 -> red on the token's
    # shape; restored, green.
    test "is minted from the base URL and a token, never the execution id" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      assert String.starts_with?(location, @base_url <> "/")
      token = token(location)
      assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      refute String.contains?(location, execution_id)
    end

    # sabotage: create_persistence_options/2 made to answer the
    # configuration's own snapshot whatever the token -> the created
    # execution's entry carried no location, red; restored, green.
    test "is the one the created execution's _ioprocessors carries, under both type strings" do
      pid = self()

      on_create = fn store, execution_id, machine, opts ->
        result = Executions.create(store, execution_id, machine, opts)
        {:ok, _execution, state} = result
        send(pid, {:created, state.datamodel["_ioprocessors"]})
        result
      end

      config = basichttp_config(on_create: on_create)
      {_execution_id, location} = loaded_parcel(config)

      assert_received {:created, ioprocessors}
      assert ioprocessors["basichttp"] == %{"location" => location}
      assert ioprocessors[@uri] == %{"location" => location}
    end

    # sabotage: ioprocessors_entry/2's no-token clause made to answer a
    # location -> red on the always_new entry; restored, green.
    test "is absent for an always_new execution, which rotation refuses" do
      pid = self()

      on_create = fn store, execution_id, machine, opts ->
        result = Executions.create(store, execution_id, machine, opts)
        {:ok, _execution, state} = result
        send(pid, {:created, state.datamodel["_ioprocessors"]})
        result
      end

      bindings = Enum.map(parcel_bindings(), &Map.put(&1, :create, :always_new))
      config = basichttp_config(bindings: bindings, on_create: on_create)

      {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
        StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert_received {:created, %{"basichttp" => entry}}
      assert entry == %{}
      assert BasicHTTP.location(config, execution_id) == {:error, :no_location}

      assert BasicHTTP.rotate_location(config, execution_id) ==
               {:error, {:no_address, execution_id}}

      assert TestRepo.all(Config.queryable(config, Location)) == []
    end

    # sabotage: rotate_location/2's insert made to leave the token as it
    # was on a conflict -> the old token still delivered, red; restored,
    # green.
    test "rotates: the old token answers 404 and the new one delivers" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)

      assert {:ok, new} = BasicHTTP.rotate_location(config, execution_id)
      assert new != old
      assert BasicHTTP.location(config, execution_id) == {:ok, new}

      answer = handle(config, post(token(old), "noted"))
      assert answer == {:error, :unknown_location}
      assert Front.response(answer) == {404, []}

      answer = handle(config, post(token(new), "noted"))
      assert answer == {:ok, {:delivered, "basichttp", execution_id}}
      assert Front.response(answer) == {204, []}
    end

    # sabotage: rotate_location/2's insert made an update of an existing
    # location only -> the row got no location and the POST answered
    # unknown_location, red; restored, green.
    test "is given by rotation to an address row written before the key was set" do
      plain = config(self(), bindings: parcel_bindings())

      {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
        StatifierRouter.route(plain, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      config = basichttp_config()
      assert BasicHTTP.location(config, execution_id) == {:error, :no_location}
      assert {:ok, location} = BasicHTTP.rotate_location(config, execution_id)

      assert handle(config, post(token(location), "noted")) ==
               {:ok, {:delivered, "basichttp", execution_id}}
    end
  end

  describe "the front" do
    # sabotage: deliver/5 in the front handed deliver_event/4 the plan
    # with the row's key replaced by "pcl_other" -> the :never lookup
    # missed and the answer was dropped: no_execution, red; restored,
    # green.
    test "delivers a POST to a persisted execution and answers 204" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered"))

      assert answer == {:ok, {:delivered, "basichttp", execution_id}}
      assert Front.response(answer) == {204, []}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]

      assert %Ledger{
               binding_id: "basichttp",
               scope: "7c1e",
               outcome: "delivered",
               key: "pcl_4821",
               execution_id: ^execution_id
             } = List.last(ledger(config))
    end

    # sabotage: address_by_token/2's where dropped -> a well-shaped
    # unknown token resolved to the one location row and delivered, red;
    # restored, green.
    test "answers 404 for an unknown location and writes nothing" do
      config = basichttp_config()
      {_execution_id, _location} = loaded_parcel(config)
      before = ledger(config)

      for token <- [BasicHTTP.mint_token(), "not-a-token"] do
        answer = handle(config, post(token, "delivered"))
        assert answer == {:error, :unknown_location}
        assert Front.response(answer) == {404, []}
      end

      assert ledger(config) == before
    end

    # sabotage: response/1's {:not_utf8, _} clause deleted -> the malformed
    # body answered 500, red; restored, green.
    test "answers 400 for a malformed body and delivers nothing" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered", %{body: <<0xFF, 0xFE>>}))

      assert answer == {:error, {:not_utf8, :body}}
      assert Front.response(answer) == {400, []}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: response/1's :method_not_allowed clause answered no allow
    # header -> red on the headers; restored, green.
    test "answers 405 with Allow: POST for a method other than POST" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered", %{method: "GET"}))

      assert answer == {:error, {:method_not_allowed, "GET"}}
      assert Front.response(answer) == {405, [{"allow", "POST"}]}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: message_id/2 made to mint a fresh id whatever the send key
    # -> the second POST was delivered again, red; restored, green.
    test "deduplicates on the scxml-send-key per execution" do
      config = basichttp_config()
      {first, first_location} = loaded_parcel(config)
      {second, second_location} = loaded_parcel(config, "parcel_scans/1/0002", "pcl_5190")

      request = post(token(first_location), "noted", %{send_key: @send_key})

      assert handle(config, request) == {:ok, {:delivered, "basichttp", first}}
      assert handle(config, request) == {:ok, {:duplicate, "basichttp"}}
      assert Front.response({:ok, {:duplicate, "basichttp"}}) == {204, []}
      assert inputs(config, first) == [{0, "step", "loaded"}, {1, "step", "noted"}]

      # The same key at another execution's location is another message.
      assert handle(config, %{request | token: token(second_location)}) ==
               {:ok, {:delivered, "basichttp", second}}

      # Without a key every POST is its own message.
      no_key = post(token(first_location), "noted")
      assert handle(config, no_key) == {:ok, {:delivered, "basichttp", first}}
      assert handle(config, no_key) == {:ok, {:delivered, "basichttp", first}}
    end

    # sabotage: resolve/2 matched any address row, stamped or not -> the
    # retry was claimed as a duplicate and answered 204, red; restored,
    # green.
    test "answers 404 for a finished execution, and again for the retry" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      assert {:ok, {:delivered, "basichttp", ^execution_id}} =
               handle(config, post(token(location), "delivered"))

      request = post(token(location), "noted", %{send_key: @send_key})
      answer = handle(config, request)
      assert answer == {:ok, {:dropped, "basichttp", :finished}}
      assert Front.response(answer) == {404, []}

      assert handle(config, request) == {:error, :unknown_location}
    end

    # sabotage: dropped :query from @required -> the refusal named :body
    # alone, red; restored, green.
    test "refuses a malformed request by naming its keys, never the token" do
      config = basichttp_config()
      {_execution_id, location} = loaded_parcel(config)

      request = Map.drop(post(token(location), "noted"), [:body, :query])

      answer = handle(config, request)
      assert answer == {:error, {:invalid_request, [:body, :query]}}
      assert Front.response(answer) == {500, []}
      refute inspect(answer) =~ token(location)

      assert Front.handle(config, post(token(location), "noted"), then: @now) ==
               {:error, {:unknown_key, :then}}
    end

    # sabotage: not_reentrant/0 made to answer :ok -> the POST from inside
    # a route delivered, red; restored, green.
    test "refuses while a route runs in the calling process" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      Process.put({StatifierRouter.SendHandler, :in_route}, execution_id)

      try do
        assert handle(config, post(token(location), "noted")) ==
                 {:error, {:reentrant_route, execution_id}}
      after
        Process.delete({StatifierRouter.SendHandler, :in_route})
      end
    end
  end

  describe "the configuration" do
    # sabotage: put_basichttp/3's nil clause made to register the
    # processor anyway -> the snapshot differed, red; restored, green.
    test "without :basichttp mints nothing and builds the snapshot as before" do
      plain = config(self(), bindings: parcel_bindings(), send_type: "myapp:router")
      assert plain.basichttp == nil

      {:ok, [{:created_and_delivered, "loaded_scans", _id}, _]} =
        StatifierRouter.route(plain, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert TestRepo.all(Config.queryable(plain, Location)) == []
      assert [%Address{}] = addresses(plain)

      assert plain.persistence_options == [
               send_types:
                 Types.from_send_types(%{
                   "myapp:router" => StatifierRouter.SendHandler
                 })
             ]
    end

    # sabotage: basichttp_shape/1 made to accept any keyword list -> the
    # empty base URL was accepted, red; restored, green.
    test "refuses a malformed :basichttp and a clash with another registration" do
      base = [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery]

      for bad <- [[], [base_url: ""], [base_url: 7], [transport: Foo], [base_url: "x", port: 1]] do
        assert Config.new(base ++ [basichttp: bad]) == {:error, {:invalid_value, :basichttp, bad}}
      end

      ok = [base_url: @base_url]

      assert Config.new(base ++ [basichttp: ok, send_handlers: %{"basichttp" => Foo}]) ==
               {:error, {:declared_send_types, "basichttp"}}

      assert Config.new(base ++ [basichttp: ok, send_type: @uri]) ==
               {:error, {:declared_send_types, @uri}}

      assert Config.new(base ++ [basichttp: ok, persistence_options: [send_types: nil]]) ==
               {:error, {:exclusive_keys, :basichttp, :send_types}}
    end

    # sabotage: refuse_reserved_id/2 made to reserve basichttp on every
    # configuration -> red on the configuration without the key; restored,
    # green.
    test "reserves the binding id basichttp only when the key is set" do
      base = [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery]
      binding = hd(parcel_bindings()) |> Map.put(:id, "basichttp")

      assert {:ok, %Config{}} = Config.new(base ++ [bindings: [binding]])

      assert Config.new(base ++ [bindings: [binding], basichttp: [base_url: @base_url]]) ==
               {:error, {:reserved_binding_id, "basichttp"}}

      resolved =
        Config.new(
          base ++
            [
              bindings_resolver: fn _scope -> [elem(StatifierRouter.Binding.new(binding), 1)] end,
              basichttp: [base_url: @base_url]
            ]
        )

      assert {:ok, config} = resolved
      assert Config.bindings_for(config, "7c1e") == {:error, {:reserved_binding_id, "basichttp"}}
    end
  end
end
