defmodule StatifierRouter.BindingTest do
  use ExUnit.Case, async: true

  alias StatifierRouter.Binding

  doctest Binding

  # The two bindings of ADR-0001's example: an impression opens an
  # execution of the join document, and its click lands on the same one.
  @impressions [
    id: "impressions_to_join",
    source: "ad_events",
    match: "event.kind == 'impression'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "impression",
    data: ["impression_id", "shown_at", "placement"]
  ]

  @clicks %{
    id: "clicks_to_join",
    source: "ad_events",
    match: "event.kind == 'click'",
    key: "event.impression_id",
    document: "impression_click_join",
    event: "click",
    data: ["impression_id", "clicked_at", "url"]
  }

  @impression %{
    "kind" => "impression",
    "impression_id" => "imp_7f3a",
    "shown_at" => "2026-09-19T07:59:00Z",
    "placement" => "sidebar"
  }

  @click %{
    "kind" => "click",
    "impression_id" => "imp_7f3a",
    "clicked_at" => "2026-09-19T08:00:00Z",
    "url" => "https://example.com/offer"
  }

  defp binding!(attrs) do
    {:ok, binding} = Binding.new(attrs)
    binding
  end

  describe "new/1 defaults and compilation" do
    # sabotage: changing the struct's dedupe default horizon_ms to 3_600_000
    # turned this test red; restored, green.
    test "fills every default the record names from a keyword list" do
      assert {:ok,
              %Binding{
                id: "impressions_to_join",
                source: "ad_events",
                selector: %{},
                document: "impression_click_join",
                event: "impression",
                data: ["impression_id", "shown_at", "placement"],
                create: :if_absent,
                dedupe: %{by: :message_id, horizon_ms: 259_200_000},
                order: :by_key,
                enabled: true
              }} = Binding.new(@impressions)
    end

    # sabotage: storing the source string in compiled_match instead of the
    # compiled program turned this test red; restored, green.
    test "compiles match and key once and keeps both programs" do
      binding = binding!(@clicks)

      assert {:ok, binding.compiled_match} == Predicator.compile("event.kind == 'click'")
      assert {:ok, binding.compiled_key} == Predicator.compile("event.impression_id")
      assert binding.match == "event.kind == 'click'"
      assert binding.key == "event.impression_id"
    end

    # sabotage: dropping the optional keys from the fields new/1 hands
    # struct!/2 turned this test red; restored, green.
    test "accepts a map and every optional key at a non-default value" do
      attrs =
        Map.merge(@clicks, %{
          selector: %{"topic" => "ad_events"},
          create: :always_new,
          dedupe: %{by: :message_id, horizon_ms: 60_000},
          order: :none,
          enabled: false
        })

      assert {:ok,
              %Binding{
                selector: %{"topic" => "ad_events"},
                create: :always_new,
                dedupe: %{by: :message_id, horizon_ms: 60_000},
                order: :none,
                enabled: false
              }} = Binding.new(attrs)
    end
  end

  describe "new/1 reserved and unknown keys" do
    # sabotage: removing :batch from @reserved turned this test red (it
    # came back {:unknown_key, :batch}); restored, green.
    test "refuses each reserved key by name" do
      for name <- [:mode, :batch, :window] do
        assert Binding.new(Map.put(@clicks, name, "anything")) == {:error, {:reserved_key, name}}
        assert Binding.new([{name, 1} | @impressions]) == {:error, {:reserved_key, name}}
      end
    end

    # sabotage: dropping refuse_reserved/1 from the map clause of new/1
    # turned this test red (it came back {:unknown_key, :colour});
    # restored, green.
    test "refuses a reserved key before any other check" do
      assert Binding.new(%{window: 5, colour: "red", id: 42}) ==
               {:error, {:reserved_key, :window}}

      assert Binding.new([{"mode", :x}, :not_a_pair]) == {:error, {:reserved_key, "mode"}}
    end

    # sabotage: making refuse_unknown/1 return :ok unconditionally turned
    # this test red; restored, green.
    test "refuses an unknown key by name" do
      assert Binding.new(Map.put(@clicks, :priority, 1)) == {:error, {:unknown_key, :priority}}
      assert Binding.new(Map.put(@clicks, "id", "x")) == {:error, {:unknown_key, "id"}}
      assert Binding.new(@impressions ++ [region: "x"]) == {:error, {:unknown_key, :region}}
    end

    # sabotage: dropping refuse_duplicates/1 from the keyword clause turned
    # this test red (the last :id won); restored, green.
    test "refuses a keyword list that repeats a key" do
      assert Binding.new(@impressions ++ [id: "again"]) == {:error, {:duplicate_key, :id}}
    end

    # sabotage: replacing the keyword_shape/1 check with :ok turned this
    # test red (Map.new/1 raised); restored, green.
    test "refuses input that is neither a map nor a keyword list" do
      assert Binding.new([:id]) == {:error, {:invalid_binding, [:id]}}
      assert Binding.new("clicks_to_join") == {:error, {:invalid_binding, "clicks_to_join"}}
    end
  end

  # The moduledoc promises one order for the faults new/1 can see without
  # an event: reserved, then unknown, then missing, then an invalid value,
  # then a program that does not compile. Reserved-before-everything is
  # pinned in the describe above; these pin each remaining adjacent pair,
  # by handing new/1 both faults of the pair at once.
  describe "new/1 check order" do
    # sabotage: swapping refuse_unknown/1 and require_keys/1 in the map
    # clause of new/1 turned this test red (it came back
    # {:missing_key, :event}); restored, green.
    test "refuses an unknown key before a missing required key" do
      attrs = @clicks |> Map.delete(:event) |> Map.put(:priority, 1)

      assert Binding.new(attrs) == {:error, {:unknown_key, :priority}}
    end

    # sabotage: swapping require_keys/1 and validate_values/1 in the map
    # clause of new/1 turned this test red (it came back
    # {:invalid_value, :enabled, "yes"}); restored, green.
    test "refuses a missing required key before an invalid value" do
      attrs = @clicks |> Map.delete(:event) |> Map.put(:enabled, "yes")

      assert Binding.new(attrs) == {:error, {:missing_key, :event}}
    end

    # sabotage: moving compile(:match, attrs.match) ahead of
    # validate_values/1 in the map clause of new/1 turned this test red (it
    # came back a {:match, _} compile error); restored, green.
    test "refuses an invalid value before a program that does not compile" do
      attrs = @clicks |> Map.put(:order, :sideways) |> Map.put(:match, "event.kind ==")

      assert Binding.new(attrs) == {:error, {:invalid_value, :order, :sideways}}
    end
  end

  describe "new/1 field validation" do
    # sabotage: dropping :document from @required turned this test red;
    # restored, green.
    test "refuses each missing required key by name" do
      for name <- [:id, :source, :match, :key, :document, :event] do
        assert Binding.new(Map.delete(@clicks, name)) == {:error, {:missing_key, name}}
      end
    end

    # sabotage: validating :id, :document and :event with is_binary/1 instead
    # of non_empty_string?/1 turned this test red; restored, green.
    test "refuses an empty or non-string id, document and event" do
      for name <- [:id, :document, :event], value <- ["", :atom, 7] do
        assert Binding.new(Map.put(@clicks, name, value)) ==
                 {:error, {:invalid_value, name, value}}
      end
    end

    # sabotage: making valid?/2 for :source, :match and :key return true
    # turned this test red; restored, green.
    test "refuses a non-string source, match and key" do
      for name <- [:source, :match, :key] do
        assert Binding.new(Map.put(@clicks, name, 7)) == {:error, {:invalid_value, name, 7}}
      end
    end

    # sabotage: making valid?(:selector, _) return true turned this test
    # red; restored, green.
    test "refuses a selector that is not a map" do
      assert Binding.new(Map.put(@clicks, :selector, ["ad_events"])) ==
               {:error, {:invalid_value, :selector, ["ad_events"]}}
    end

    # sabotage: dropping the data_path?/1 check (is_list/1 alone) turned this
    # test red; restored, green.
    test "refuses data that is not a list of dotted paths" do
      for value <- ["url", [:url], ["url", ""], ["placement..slot"], [".url"], ["url."]] do
        assert Binding.new(Map.put(@clicks, :data, value)) ==
                 {:error, {:invalid_value, :data, value}}
      end
    end

    # sabotage: adding :sometimes to the :create allow-list turned this test
    # red; restored, green.
    test "refuses a create, order or enabled value outside its set" do
      for {name, value} <- [
            create: :sometimes,
            create: "if_absent",
            order: :by_time,
            order: "none",
            enabled: "true",
            enabled: nil
          ] do
        assert Binding.new(Map.put(@clicks, name, value)) ==
                 {:error, {:invalid_value, name, value}}
      end
    end

    # sabotage: dropping the map_size(value) == 2 guard on valid?(:dedupe, _)
    # turned this test red; restored, green.
    test "refuses a dedupe that is not by message id with a positive horizon" do
      for value <- [
            %{by: :message_id, horizon_ms: 0},
            %{by: :message_id, horizon_ms: -1},
            %{by: :message_id, horizon_ms: 1.5},
            %{by: :payload_hash, horizon_ms: 1_000},
            %{by: :message_id},
            %{by: :message_id, horizon_ms: 1_000, extra: true},
            [by: :message_id, horizon_ms: 1_000]
          ] do
        assert Binding.new(Map.put(@clicks, :dedupe, value)) ==
                 {:error, {:invalid_value, :dedupe, value}}
      end
    end

    # sabotage: making compile/2 tag every error as :match turned this test
    # red; restored, green.
    test "refuses a match or key that does not compile, naming which" do
      assert {:error, {:match, %Predicator.Errors.ParseError{}}} =
               Binding.new(Map.put(@clicks, :match, "event.kind =="))

      assert {:error, {:key, %Predicator.Errors.ParseError{}}} =
               Binding.new(Map.put(@clicks, :key, ""))
    end
  end

  describe "match/2" do
    # sabotage: binding the event under "evt" instead of "event" in
    # evaluate/2 turned this test red; restored, green.
    test "holds only for its own kind of event" do
      assert Binding.match(binding!(@impressions), @impression) == true
      assert Binding.match(binding!(@impressions), @click) == false
      assert Binding.match(binding!(@clicks), @click) == true
      assert Binding.match(binding!(@clicks), @impression) == false
    end

    # sabotage: mapping {:ok, :undefined} to false turned this test red;
    # restored, green.
    test "returns :undefined when the field it reads is missing" do
      assert Binding.match(binding!(@clicks), %{"impression_id" => "imp_7f3a"}) == :undefined
    end

    # sabotage: removing the {:ok, nil} clause (nil fell to {:non_boolean,
    # nil}) turned this test red; restored, green.
    test "returns false when the program evaluates to nil" do
      binding = binding!(Map.put(@clicks, :match, "event.kind"))
      assert Binding.match(binding, %{"kind" => nil}) == false
    end

    # sabotage: mapping {:ok, other} to false turned this test red;
    # restored, green.
    test "refuses a program that evaluates to a non-boolean" do
      binding = binding!(Map.put(@clicks, :match, "event.kind"))
      assert Binding.match(binding, @click) == {:refused, {:non_boolean, "click"}}
    end

    # sabotage: mapping {:error, _} to :undefined turned this test red;
    # restored, green.
    test "refuses a program whose evaluation returns an error" do
      binding = binding!(Map.put(@clicks, :match, "not event.clicked"))

      assert {:refused, {:evaluation_error, %Predicator.Errors.TypeMismatchError{}}} =
               Binding.match(binding, @click)
    end
  end

  describe "key/2" do
    # sabotage: returning {:ok, "imp"} in place of the evaluated key turned
    # this test red; restored, green.
    test "returns the key a click and its impression share" do
      assert Binding.key(binding!(@impressions), @impression) == {:ok, "imp_7f3a"}
      assert Binding.key(binding!(@clicks), @click) == {:ok, "imp_7f3a"}
    end

    # sabotage: dropping the is_binary(key) guard turned this test red (the
    # integer came back {:ok, 7310}); restored, green.
    test "refuses a key that is not a string" do
      assert Binding.key(binding!(@clicks), Map.put(@click, "impression_id", 7310)) ==
               {:refused, {:invalid_key, 7310}}

      assert Binding.key(binding!(@clicks), Map.put(@click, "impression_id", nil)) ==
               {:refused, {:invalid_key, nil}}
    end

    # sabotage: dropping the key != "" guard turned this test red; restored,
    # green.
    test "refuses an empty key" do
      assert Binding.key(binding!(@clicks), Map.put(@click, "impression_id", "")) ==
               {:refused, {:invalid_key, ""}}
    end

    # sabotage: mapping {:ok, :undefined} to {:ok, ""} ahead of the other
    # clauses turned this test red; restored, green.
    test "refuses a key the event does not carry" do
      assert Binding.key(binding!(@clicks), Map.delete(@click, "impression_id")) ==
               {:refused, {:invalid_key, :undefined}}
    end

    # sabotage: mapping {:error, _} to {:refused, {:invalid_key, nil}} turned
    # this test red; restored, green.
    test "refuses a key whose evaluation returns an error" do
      binding = binding!(Map.put(@clicks, :key, "event.impression_id * 2"))

      assert {:refused, {:evaluation_error, %Predicator.Errors.TypeMismatchError{}}} =
               Binding.key(binding, @click)
    end
  end

  describe "project/2" do
    # sabotage: starting the projection from the whole event instead of
    # the empty map turned this test red; restored, green.
    test "carries exactly the listed fields of a click" do
      assert Binding.project(binding!(@clicks), Map.put(@click, "user_agent", "x")) == %{
               "impression_id" => "imp_7f3a",
               "clicked_at" => "2026-09-19T08:00:00Z",
               "url" => "https://example.com/offer"
             }
    end

    # sabotage: putting nil for a missing path instead of skipping it turned
    # this test red; restored, green.
    test "leaves out a path the event does not carry" do
      assert Binding.project(binding!(@clicks), Map.delete(@click, "url")) == %{
               "impression_id" => "imp_7f3a",
               "clicked_at" => "2026-09-19T08:00:00Z"
             }
    end

    # sabotage: writing each value under the whole path string as a flat key
    # turned this test red; restored, green.
    test "reads and writes a dotted path as nested maps" do
      binding =
        binding!(Keyword.put(@impressions, :data, ["placement.slot", "placement.page", "size.w"]))

      impression =
        Map.merge(@impression, %{
          "placement" => %{"slot" => "sidebar", "page" => "/offers", "rank" => 2},
          "size" => "300x250"
        })

      assert Binding.project(binding, impression) == %{
               "placement" => %{"slot" => "sidebar", "page" => "/offers"}
             }
    end

    # sabotage: skipping a key whose value is nil in project/2 turned this
    # test red; restored, green.
    test "carries a field the event carries as nil" do
      binding = binding!(Map.put(@clicks, :data, ["url"]))
      assert Binding.project(binding, Map.put(@click, "url", nil)) == %{"url" => nil}
    end
  end
end
