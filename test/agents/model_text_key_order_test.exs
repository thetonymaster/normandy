defmodule Normandy.Agents.ModelTextKeyOrderTest do
  @moduledoc """
  Task 6.1f (decision 25, A1): the JSON text Normandy writes for the model from a plain
  map lists its keys sorted, at every depth, so the same tool result is the same text on
  every node and after a restart (a stable prompt-cache prefix). On OTP 26+ a small
  atom-keyed map iterates its keys in atom-creation order, so before this task the text
  depended on which atom the VM happened to create first.

  The keys here are atoms created at test time in reverse alphabetical order, so the
  unsorted encoding lists them zeta, mid, alpha. A struct with its own `Jason.Encoder`
  and a `Jason.OrderedObject` keep their order; values and list order never change.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.ToolResult
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule Plain do
    @moduledoc false
    defstruct [:zulu, :alpha, :nested]
  end

  defmodule Derived do
    @moduledoc false
    @derive {Jason.Encoder, only: [:zulu, :alpha]}
    defstruct [:zulu, :alpha]
  end

  # Three atoms created now, in reverse alphabetical order (zeta, mid, alpha).
  defp fresh_keys do
    suffix = System.unique_integer([:positive])
    for name <- ["zeta", "mid", "alpha"], do: String.to_atom("#{name}_#{suffix}")
  end

  # A tool output with atom keys at three depths, a string key among them, and a list of
  # maps; and its text with every object's keys sorted.
  defp output_and_text do
    [z, m, a] = fresh_keys()
    [z2, m2, a2] = fresh_keys()

    output = %{
      z => 1,
      "beta" => "b",
      m => %{z2 => "x", a2 => "y"},
      a => [%{m2 => true, a2 => false}, 3]
    }

    text =
      ~s({"#{a}":[{"#{a2}":false,"#{m2}":true},3],"beta":"b",) <>
        ~s("#{m}":{"#{a2}":"y","#{z2}":"x"},"#{z}":1})

    {output, text}
  end

  defp result_text(output) do
    [%{content: text}] = BaseIOSchema.to_json(%ToolResult{tool_call_id: "t", output: output})
    text
  end

  describe "the encoding" do
    test "a tool's map output is sent with its keys sorted, at every depth" do
      {output, text} = output_and_text()

      assert result_text(output) == text
      assert ToolResult.render_output(output) == text
      # The same values: only the order of the keys changed.
      assert Jason.decode!(text) == Jason.decode!(Normandy.JSON.encode!(output))
    end

    test "map content is sent with its keys sorted" do
      {output, text} = output_and_text()

      assert BaseIOSchema.to_json(output) == text
    end

    test "a struct with its own encoder and an OrderedObject keep their order; maps in an OrderedObject are sorted" do
      [z, _m, a] = fresh_keys()

      output = %{
        "struct" => %Derived{zulu: 1, alpha: 2},
        "ordered" => Jason.OrderedObject.new([{"zulu", %{z => 1, a => 2}}, {"alpha", 0}])
      }

      assert result_text(output) ==
               ~s({"ordered":{"zulu":{"#{a}":2,"#{z}":1},"alpha":0},) <>
                 ~s("struct":{"zulu":1,"alpha":2}})
    end
  end

  describe "structs without an encoder, integer keys and ties" do
    test "a struct without its own encoder is written as its sorted fields, nested maps sorted" do
      [z, _m, a] = fresh_keys()
      plain = %Plain{zulu: 1, alpha: 2, nested: %{z => 1, a => 2}}

      assert result_text(%{"s" => plain}) ==
               ~s({"s":{"alpha":2,"nested":{"#{a}":2,"#{z}":1},"zulu":1}})
    end

    test "integer keys sort by their text" do
      assert result_text(%{10 => "c", 2 => "b", 1 => "a"}) == ~s({"1":"a","10":"c","2":"b"})
    end

    test "\"a\" and :a tie deterministically whatever the map's order" do
      expected = ~s({"a":2,"a":1})
      assert result_text(%{"a" => 1, a: 2}) == expected
      assert result_text(Map.new([{:a, 2}, {"a", 1}])) == expected
    end
  end

  describe "on every path" do
    @replies [
      {[%{"type" => "tool_use", "id" => "t1", "name" => "facts", "input" => %{}}], "tool_use"},
      {[%{"type" => "text", "text" => "Done."}], "end_turn"}
    ]

    defp json_replies, do: Enum.map(@replies, fn {blocks, stop} -> {:json, blocks, stop} end)

    defp sse_replies do
      for {{[block], stop}, i} <- Enum.with_index(@replies) do
        events =
          case block do
            %{"type" => "tool_use"} ->
              WireScript.block(0, block, [
                %{"type" => "input_json_delta", "partial_json" => "{}"}
              ])

            %{"type" => "text", "text" => text} ->
              WireScript.block(0, %{"type" => "text", "text" => ""}, [
                %{"type" => "text_delta", "text" => text}
              ])
          end

        {:sse, WireScript.message("msg_#{i}", events, stop)}
      end
    end

    defp agent(client, output) do
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        max_tokens: 1024,
        toolset: Toolset.new([%ReturnTool{name: "facts", output: output}])
      })
    end

    # The tool_result texts in the request that follows the tool round.
    defp sent_results do
      assert_received {:wire_body, 1, body}

      for %{"content" => blocks} when is_list(blocks) <- body["messages"],
          %{"type" => "tool_result", "content" => content} <- blocks,
          do: content
    end

    test "run/3" do
      {output, text} = output_and_text()
      config = agent(WireScript.client(json_replies()), output)

      assert {:ok, _config, _out} = BaseAgent.run(config, "go")
      assert sent_results() == [text]
    end

    test "stream/3" do
      {output, text} = output_and_text()
      config = agent(WireScript.client(sse_replies()), output)

      assert {:ok, _config, _out} = BaseAgent.stream(config, "go", fn _event -> :ok end)
      assert sent_results() == [text]
    end

    test "Turn.Server" do
      {output, text} = output_and_text()

      {:ok, srv} =
        Server.start_link(
          session_id: "key-order-#{System.unique_integer([:positive])}",
          config: agent(WireScript.client(json_replies()), output),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, _out} = Server.run(srv, "go")
      assert sent_results() == [text]
    end
  end
end
