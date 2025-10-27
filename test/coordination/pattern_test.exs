defmodule Normandy.Coordination.PatternTest do
  use ExUnit.Case, async: true
  doctest Normandy.Coordination.Pattern

  alias Normandy.Coordination.Pattern

  describe "ok?/1" do
    test "returns true for {:ok, value}" do
      assert Pattern.ok?({:ok, "value"})
      assert Pattern.ok?({:ok, 123})
      assert Pattern.ok?({:ok, nil})
    end

    test "returns false for {:error, reason}" do
      refute Pattern.ok?({:error, "reason"})
      refute Pattern.ok?({:error, :bad})
    end

    test "returns false for other values" do
      refute Pattern.ok?("not a tuple")
      refute Pattern.ok?(nil)
      refute Pattern.ok?({:other, "value"})
    end
  end

  describe "error?/1" do
    test "returns true for {:error, reason}" do
      assert Pattern.error?({:error, "reason"})
      assert Pattern.error?({:error, :bad})
      assert Pattern.error?({:error, nil})
    end

    test "returns false for {:ok, value}" do
      refute Pattern.error?({:ok, "value"})
      refute Pattern.error?({:ok, 123})
    end

    test "returns false for other values" do
      refute Pattern.error?("not a tuple")
      refute Pattern.error?(nil)
      refute Pattern.error?({:other, "reason"})
    end
  end

  describe "ok!/2" do
    test "extracts value from {:ok, value}" do
      assert Pattern.ok!({:ok, "value"}) == "value"
      assert Pattern.ok!({:ok, 123}) == 123
      assert Pattern.ok!({:ok, nil}) == nil
    end

    test "returns default for {:error, reason}" do
      assert Pattern.ok!({:error, "reason"}, default: "fallback") == "fallback"
      assert Pattern.ok!({:error, "reason"}, default: nil) == nil
    end

    test "returns nil by default for errors" do
      assert Pattern.ok!({:error, "reason"}) == nil
    end
  end

  describe "error!/2" do
    test "extracts reason from {:error, reason}" do
      assert Pattern.error!({:error, "reason"}) == "reason"
      assert Pattern.error!({:error, :bad}) == :bad
    end

    test "returns default for {:ok, value}" do
      assert Pattern.error!({:ok, "value"}, default: "no error") == "no error"
      assert Pattern.error!({:ok, "value"}, default: nil) == nil
    end

    test "returns nil by default for success" do
      assert Pattern.error!({:ok, "value"}) == nil
    end
  end

  describe "filter_ok/1" do
    test "filters successful results" do
      results = [{:ok, 1}, {:error, "bad"}, {:ok, 2}, {:ok, 3}]
      assert Pattern.filter_ok(results) == [1, 2, 3]
    end

    test "returns empty list when no successes" do
      results = [{:error, "bad"}, {:error, "worse"}]
      assert Pattern.filter_ok(results) == []
    end

    test "returns all values when all successful" do
      results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert Pattern.filter_ok(results) == [1, 2, 3]
    end

    test "handles empty list" do
      assert Pattern.filter_ok([]) == []
    end
  end

  describe "filter_errors/1" do
    test "filters error results" do
      results = [{:ok, 1}, {:error, "bad"}, {:ok, 2}, {:error, "worse"}]
      assert Pattern.filter_errors(results) == ["bad", "worse"]
    end

    test "returns empty list when no errors" do
      results = [{:ok, 1}, {:ok, 2}]
      assert Pattern.filter_errors(results) == []
    end

    test "returns all reasons when all errors" do
      results = [{:error, "bad"}, {:error, "worse"}, {:error, "worst"}]
      assert Pattern.filter_errors(results) == ["bad", "worse", "worst"]
    end

    test "handles empty list" do
      assert Pattern.filter_errors([]) == []
    end
  end

  describe "map_ok/2" do
    test "transforms successful result" do
      result = Pattern.map_ok({:ok, "hello"}, &String.upcase/1)
      assert result == {:ok, "HELLO"}
    end

    test "leaves error unchanged" do
      result = Pattern.map_ok({:error, "reason"}, &String.upcase/1)
      assert result == {:error, "reason"}
    end

    test "works with complex transformations" do
      result =
        {:ok, "  hello  "}
        |> Pattern.map_ok(&String.trim/1)
        |> Pattern.map_ok(&String.upcase/1)

      assert result == {:ok, "HELLO"}
    end
  end

  describe "map_error/2" do
    test "transforms error result" do
      result = Pattern.map_error({:error, "reason"}, &String.upcase/1)
      assert result == {:error, "REASON"}
    end

    test "leaves success unchanged" do
      result = Pattern.map_error({:ok, "value"}, &String.upcase/1)
      assert result == {:ok, "value"}
    end

    test "works with complex transformations" do
      result =
        {:error, "  bad  "}
        |> Pattern.map_error(&String.trim/1)
        |> Pattern.map_error(&String.upcase/1)

      assert result == {:error, "BAD"}
    end
  end

  describe "then/2" do
    test "chains successful results" do
      result =
        {:ok, "  hello  "}
        |> Pattern.then(&{:ok, String.trim(&1)})
        |> Pattern.then(&{:ok, String.upcase(&1)})

      assert result == {:ok, "HELLO"}
    end

    test "stops at first error" do
      result =
        {:ok, "hello"}
        |> Pattern.then(fn _ -> {:error, "failed"} end)
        |> Pattern.then(&{:ok, String.upcase(&1)})

      assert result == {:error, "failed"}
    end

    test "propagates initial error" do
      result =
        {:error, "initial error"}
        |> Pattern.then(&{:ok, String.trim(&1)})
        |> Pattern.then(&{:ok, String.upcase(&1)})

      assert result == {:error, "initial error"}
    end
  end

  describe "find_ok/1" do
    test "returns first successful result" do
      results = [{:error, "bad"}, {:ok, "good"}, {:ok, "also good"}]
      assert Pattern.find_ok(results) == {:ok, "good"}
    end

    test "returns last error if all failed" do
      results = [{:error, "bad"}, {:error, "worse"}, {:error, "worst"}]
      assert Pattern.find_ok(results) == {:error, "worst"}
    end

    test "handles empty list" do
      assert Pattern.find_ok([]) == {:error, :no_results}
    end

    test "returns first when all successful" do
      results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert Pattern.find_ok(results) == {:ok, 1}
    end
  end

  describe "collect_ok/1" do
    test "collects all successful results" do
      results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert Pattern.collect_ok(results) == {:ok, [1, 2, 3]}
    end

    test "collects partial successes" do
      results = [{:ok, 1}, {:error, "bad"}, {:ok, 3}]
      assert Pattern.collect_ok(results) == {:ok, [1, 3]}
    end

    test "returns errors when all failed" do
      results = [{:error, "bad"}, {:error, "worse"}]
      assert Pattern.collect_ok(results) == {:error, ["bad", "worse"]}
    end
  end

  describe "all_ok/1" do
    test "returns all values when all successful" do
      results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert Pattern.all_ok(results) == {:ok, [1, 2, 3]}
    end

    test "returns errors when any failed" do
      results = [{:ok, 1}, {:error, "bad"}, {:ok, 3}]
      assert Pattern.all_ok(results) == {:error, ["bad"]}
    end

    test "returns all errors when all failed" do
      results = [{:error, "bad"}, {:error, "worse"}]
      assert Pattern.all_ok(results) == {:error, ["bad", "worse"]}
    end

    test "handles empty list" do
      assert Pattern.all_ok([]) == {:ok, []}
    end
  end

  describe "all_ok_map/1" do
    test "returns map of values when all successful" do
      results = %{a: {:ok, 1}, b: {:ok, 2}, c: {:ok, 3}}
      assert Pattern.all_ok_map(results) == {:ok, %{a: 1, b: 2, c: 3}}
    end

    test "returns map of errors when any failed" do
      results = %{a: {:ok, 1}, b: {:error, "bad"}, c: {:ok, 3}}
      assert Pattern.all_ok_map(results) == {:error, %{b: "bad"}}
    end

    test "returns all errors when multiple failed" do
      results = %{a: {:ok, 1}, b: {:error, "bad"}, c: {:error, "worse"}}
      assert Pattern.all_ok_map(results) == {:error, %{b: "bad", c: "worse"}}
    end

    test "handles empty map" do
      assert Pattern.all_ok_map(%{}) == {:ok, %{}}
    end
  end

  describe "unwrap!/1" do
    test "unwraps successful result" do
      assert Pattern.unwrap!({:ok, "value"}) == "value"
      assert Pattern.unwrap!({:ok, 123}) == 123
    end

    test "raises on error" do
      assert_raise RuntimeError, ~r/Unwrap failed/, fn ->
        Pattern.unwrap!({:error, "reason"})
      end
    end
  end

  describe "wrap/1" do
    test "wraps plain value" do
      assert Pattern.wrap("value") == {:ok, "value"}
      assert Pattern.wrap(123) == {:ok, 123}
      assert Pattern.wrap(nil) == {:ok, nil}
    end

    test "leaves {:ok, value} unchanged" do
      assert Pattern.wrap({:ok, "value"}) == {:ok, "value"}
    end

    test "leaves {:error, reason} unchanged" do
      assert Pattern.wrap({:error, "reason"}) == {:error, "reason"}
    end
  end

  describe "try_wrap/1" do
    test "wraps successful function call" do
      result = Pattern.try_wrap(fn -> 1 + 1 end)
      assert result == {:ok, 2}
    end

    test "catches exceptions" do
      result = Pattern.try_wrap(fn -> raise "boom" end)
      assert {:error, %RuntimeError{message: "boom"}} = result
    end

    test "catches different exception types" do
      result = Pattern.try_wrap(fn -> raise ArgumentError, "invalid" end)
      assert {:error, %ArgumentError{message: "invalid"}} = result
    end
  end

  describe "integration scenarios" do
    test "chaining operations with map_ok and then" do
      result =
        {:ok, "  hello world  "}
        |> Pattern.map_ok(&String.trim/1)
        |> Pattern.then(fn s ->
          if String.length(s) > 5 do
            {:ok, String.upcase(s)}
          else
            {:error, :too_short}
          end
        end)

      assert result == {:ok, "HELLO WORLD"}
    end

    test "processing multiple agent results" do
      agent_results = %{
        "agent_0" => {:ok, %{confidence: 0.9, answer: "yes"}},
        "agent_1" => {:ok, %{confidence: 0.8, answer: "yes"}},
        "agent_2" => {:error, :timeout}
      }

      # Extract all successful results
      {:ok, successes} = Pattern.collect_ok(Map.values(agent_results))
      assert length(successes) == 2

      # Check if all results agree
      answers = Enum.map(successes, & &1.answer)
      assert Enum.all?(answers, &(&1 == "yes"))
    end

    test "fail-fast with all_ok" do
      results = [
        {:ok, 1},
        {:ok, 2},
        {:error, "computation failed"},
        {:ok, 4}
      ]

      assert {:error, ["computation failed"]} = Pattern.all_ok(results)
    end

    test "transform and collect results" do
      results = [
        {:ok, "hello"},
        {:ok, "world"},
        {:error, "bad"}
      ]

      final =
        results
        |> Enum.map(&Pattern.map_ok(&1, fn s -> String.upcase(s) end))
        |> Pattern.collect_ok()

      assert final == {:ok, ["HELLO", "WORLD"]}
    end
  end
end
