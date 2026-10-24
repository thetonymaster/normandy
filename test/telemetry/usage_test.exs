defmodule Normandy.Telemetry.UsageTest do
  use ExUnit.Case, async: true

  alias Normandy.Telemetry.Usage

  doctest Usage

  defmodule UsageStruct do
    defstruct [
      :input_tokens,
      :output_tokens,
      :cache_read_input_tokens,
      :cache_creation_input_tokens
    ]
  end

  test "sums cache read and write into input_tokens (atom keys)" do
    assert Usage.normalize(%{
             input_tokens: 10,
             output_tokens: 5,
             cache_read_input_tokens: 100,
             cache_creation_input_tokens: 20
           }) == %{
             input_tokens: 130,
             output_tokens: 5,
             cache_read_input_tokens: 100,
             cache_write_input_tokens: 20
           }
  end

  test "accepts string keys and mixed keys" do
    assert Usage.normalize(%{
             "input_tokens" => 3,
             "output_tokens" => 4,
             "cache_read_input_tokens" => 7
           }) ==
             %{input_tokens: 10, output_tokens: 4, cache_read_input_tokens: 7}

    assert Usage.normalize(%{:input_tokens => 3, "cache_creation_input_tokens" => 2}) ==
             %{input_tokens: 5, cache_write_input_tokens: 2}
  end

  test "accepts a struct" do
    assert Usage.normalize(%UsageStruct{
             input_tokens: 1,
             output_tokens: 2,
             cache_read_input_tokens: 3
           }) ==
             %{input_tokens: 4, output_tokens: 2, cache_read_input_tokens: 3}
  end

  test "omits absent and nil counts, never 0" do
    assert Usage.normalize(%{input_tokens: 5, output_tokens: nil, cache_read_input_tokens: nil}) ==
             %{input_tokens: 5}

    assert Usage.normalize(%{output_tokens: 9}) == %{output_tokens: 9}
  end

  test "reports nothing when the provider reports nothing" do
    assert Usage.normalize(nil) == %{}
    assert Usage.normalize(%{}) == %{}
    assert Usage.normalize("usage") == %{}
    assert Usage.normalize(%{input_tokens: nil, output_tokens: nil}) == %{}
  end

  test "sums across iterations and ignores the top-level counts" do
    usage = %{
      input_tokens: 10,
      output_tokens: 5,
      iterations: [
        %{"type" => "message", "input_tokens" => 10, "output_tokens" => 1},
        %{
          "type" => "fallback_message",
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cache_read_input_tokens" => 50,
          "cache_creation_input_tokens" => 4
        },
        %{"type" => "compaction", "input_tokens" => 7, "output_tokens" => 2}
      ]
    }

    assert Usage.normalize(usage) == %{
             input_tokens: 10 + 10 + 50 + 4 + 7,
             output_tokens: 8,
             cache_read_input_tokens: 50,
             cache_write_input_tokens: 4
           }
  end

  test "an empty or nil iterations list falls back to the top-level counts" do
    assert Usage.normalize(%{input_tokens: 2, output_tokens: 3, iterations: []}) ==
             %{input_tokens: 2, output_tokens: 3}

    assert Usage.normalize(%{input_tokens: 2, iterations: nil}) == %{input_tokens: 2}
  end

  test "iterations with no usable entries fall back to the top-level counts" do
    assert Usage.normalize(%{input_tokens: 2, output_tokens: 3, iterations: [nil, "x", %{}]}) ==
             %{input_tokens: 2, output_tokens: 3}
  end

  describe "OpenAI-shaped usage" do
    test "string keys: prompt_tokens is the input total, completion_tokens the output" do
      assert Usage.normalize(%{"prompt_tokens" => 9, "completion_tokens" => 4}) ==
               %{input_tokens: 9, output_tokens: 4}
    end

    test "atom keys work too" do
      assert Usage.normalize(%{prompt_tokens: 9, completion_tokens: 4}) ==
               %{input_tokens: 9, output_tokens: 4}
    end

    test "cached_tokens is reported as cache read without being added again" do
      usage = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 7,
        "prompt_tokens_details" => %{"cached_tokens" => 60}
      }

      assert Usage.normalize(usage) ==
               %{input_tokens: 100, output_tokens: 7, cache_read_input_tokens: 60}
    end

    test "absent counts are omitted" do
      assert Usage.normalize(%{"prompt_tokens" => 5}) == %{input_tokens: 5}
    end

    test "a map with input_tokens keeps Anthropic semantics" do
      assert Usage.normalize(%{input_tokens: 5, prompt_tokens: 99}) == %{input_tokens: 5}
    end
  end

  describe "sum/2" do
    test "a missing side returns the other" do
      assert Usage.sum(nil, %{input_tokens: 1}) == %{input_tokens: 1}
      assert Usage.sum(%{input_tokens: 1}, nil) == %{input_tokens: 1}
      assert Usage.sum(nil, nil) == nil
    end

    test "sums integer counts and lets the later side win for other values" do
      assert Usage.sum(%{input_tokens: 3, service_tier: "a"}, %{
               input_tokens: 4,
               service_tier: "b"
             }) ==
               %{input_tokens: 7, service_tier: "b"}
    end

    test "a string-keyed (wire) side adds to an atom-keyed one" do
      assert Usage.sum(%{input_tokens: 10, output_tokens: 5}, %{
               "input_tokens" => 3,
               "output_tokens" => 2,
               "not_a_usage_key_anywhere" => 1
             }) ==
               %{"not_a_usage_key_anywhere" => 1, input_tokens: 13, output_tokens: 7}
    end

    test "accepts a struct side" do
      sum = Usage.sum(struct(UsageStruct, input_tokens: 2), %{input_tokens: 5})
      assert sum.input_tokens == 7
    end

    test "iterations of both sides are concatenated, a side without one contributes its counts" do
      sum =
        Usage.sum(
          %{input_tokens: 1, output_tokens: 1, iterations: [%{"input_tokens" => 1}]},
          %{input_tokens: 4, output_tokens: 2}
        )

      assert sum.iterations == [
               %{"input_tokens" => 1},
               %{"input_tokens" => 4, "output_tokens" => 2}
             ]
    end
  end
end
