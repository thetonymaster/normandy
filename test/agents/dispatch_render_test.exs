defmodule Normandy.Agents.DispatchRenderTest do
  @moduledoc """
  Task 7.0a (A4): Dispatch renders a tool output once, with `ToolResult.render/1`: the
  text memory sent before, and the same outputs fail it as failed `Normandy.JSON.encode/1`
  (so no output becomes, or stops being, an error result). An output JSON cannot write
  is described by the exception's module, never its message (row 11).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Normandy.Agents.Dispatch
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.ReturnTool
  alias Normandy.Tools.Toolset

  defp leaf do
    one_of([
      integer(),
      float(),
      boolean(),
      constant(nil),
      atom(:alphanumeric),
      string(:printable),
      binary(),
      constant(self()),
      constant(make_ref()),
      tuple({integer(), atom(:alphanumeric)})
    ])
  end

  defp key, do: one_of([atom(:alphanumeric), string(:printable), integer(), constant({:k, 1})])

  defp output do
    tree(leaf(), fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(key(), child, max_length: 3),
        constant([1 | 2])
      ])
    end)
  end

  # Wrapped in a list: a bare binary or number is not encoded (Dispatch checks a binary's
  # UTF-8 itself), and Dispatch encodes only the other outputs.
  property "render/1 fails exactly on the outputs Normandy.JSON.encode/1 fails on" do
    check all(term <- map(output(), &[&1]), max_runs: 500) do
      assert match?({:ok, _}, ToolResult.render(term)) ==
               match?({:ok, _}, Normandy.JSON.encode(term))
    end
  end

  # The text memory sent before Task 7.0a (ToolResult.render_output/1 was sort_keys then
  # encode!): the wire does not change.
  property "render/1 gives the text sort_keys then encode! gave, or that call's exception" do
    check all(term <- map(output(), &[&1])) do
      expected =
        try do
          {:ok, term |> Normandy.JSON.sort_keys() |> Normandy.JSON.encode!()}
        rescue
          exception -> {:error, exception.__struct__}
        end

      actual =
        case ToolResult.render(term) do
          {:ok, text} -> {:ok, text}
          {:error, %module{}} -> {:error, module}
        end

      assert actual == expected
    end
  end

  defp dispatch(output) do
    config = %{toolset: Toolset.new([%ReturnTool{name: "t", output: output}])}
    Dispatch.dispatch_one(config, %ToolCall{id: "c1", name: "t", input: %{}})
  end

  test "an output with invalid UTF-8 inside is described by the exception's module" do
    assert %ToolResult{is_error: true, output: text} = dispatch(%{"rows" => <<0xFF, "secret">>})

    assert text ==
             "the tool ran, but its output cannot be sent as JSON: encoding it raised Jason.EncodeError"

    refute text =~ "secret"
  end

  test "an output with a tuple key is described by the value's type" do
    assert %ToolResult{is_error: true, output: text} = dispatch(%{{:k, 1} => 1})

    assert text ==
             "the tool ran, but its output cannot be sent as JSON: it contains a tuple"
  end
end
