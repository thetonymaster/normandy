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
end
