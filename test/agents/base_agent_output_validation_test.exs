defmodule Normandy.Agents.BaseAgentOutputValidationTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn.Server
  alias Normandy.Agents.ValidationMiddleware
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.StubClient

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true, enum: ["approve", "deny"])
    end
  end

  defmodule PlainResp do
    defstruct content: "", tool_calls: nil
  end

  defp agent(action) do
    BaseAgent.init(%{
      client: %StubClient{reply: fn _rm -> %Decision{action: action} end},
      model: "m",
      output_schema: %Decision{}
    })
  end

  # A tool-using agent whose model answers `text` without calling a tool.
  defp tool_agent(text, options \\ %{}) do
    BaseAgent.init(%{
      client: %StubClient{
        notify: self(),
        options: options,
        reply: fn rm -> %{rm | content: text, tool_calls: []} end
      },
      model: "m",
      output_schema: %Decision{}
    })
    |> BaseAgent.register_tool(%Normandy.Tools.Examples.Calculator{})
  end

  test "a valid output is returned" do
    assert {:ok, _config, %Decision{action: "approve"}} =
             BaseAgent.run(agent("approve"), %{chat_message: "x"})
  end

  test "an output outside its schema is {:error, %ValidationError{}}, with nothing on stderr" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:result, BaseAgent.run(agent("delete_everything"), %{chat_message: "x"})})
      end)

    assert_received {:result, {:error, %ValidationError{errors: [_ | _]}}}
    assert stderr == ""
  end

  test "Turn.Server replies the ValidationError and does not save the answer" do
    store = InMemory.new()

    {:ok, srv} =
      Server.start_link(
        session_id: "s-invalid-out",
        config: agent("delete_everything"),
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    assert {:error, %ValidationError{}} =
             Server.run(srv, %{chat_message: "x"})

    assert {:ok, entries} = InMemory.history(store, "s-invalid-out")
    refute Enum.any?(entries, &(&1.role == "assistant"))
  end

  test "a same-struct output of a schema without validation support stays that struct" do
    config = %BaseAgentConfig{output_schema: %PlainResp{}}

    assert {:ok, %PlainResp{content: "hi"}} =
             ValidationMiddleware.validate_output(config, %PlainResp{content: "hi"})
  end

  defmodule Note do
    use Normandy.Schema

    io_schema "A note" do
      field(:text, :string, required: true)
      field(:tag, :string)
      field(:decision, Decision)
    end
  end

  test "a nil field of a struct output is an absent one, at every depth" do
    config = %BaseAgentConfig{output_schema: %Note{}}
    note = %Note{text: "t", decision: %Decision{action: "deny"}}

    assert {:ok, ^note} = ValidationMiddleware.validate_output(config, note)

    assert {:error, [%{path: [:text], constraint: :required} | _]} =
             ValidationMiddleware.validate_output(config, %Note{})
  end

  describe "a tool-using agent with a custom output schema" do
    test "its final JSON text is parsed into the schema" do
      assert {:ok, _config, %Decision{action: "deny"}} =
               BaseAgent.run(tool_agent(~s({"action": "deny"})), %{chat_message: "x"})
    end

    test "is told the output schema on the tool-loop call" do
      {:ok, _config, _out} =
        BaseAgent.run(tool_agent(~s({"action": "deny"})), %{chat_message: "x"})

      assert_receive {:converse, %Normandy.LLM.Request{system: prompt}, _}
      assert prompt =~ "# OUTPUT SCHEMA"
      assert prompt =~ ~s("action")
      refute prompt =~ "tool_calls"
    end

    test "non-JSON final text under on_parse_failure: :error is an :invalid_output LLMError" do
      assert {:error, %LLMError{type: :invalid_output}} =
               BaseAgent.run(tool_agent("not json", %{on_parse_failure: :error}), %{
                 chat_message: "x"
               })
    end

    test "under Turn.Server, non-JSON final text replies the :invalid_output LLMError" do
      {:ok, srv} =
        Server.start_link(
          session_id: "s-unparsed-out",
          config: tool_agent("not json", %{on_parse_failure: :error}),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, %LLMError{type: :invalid_output}} =
               Server.run(srv, %{chat_message: "x"})
    end

    test "final JSON outside the schema is a ValidationError" do
      assert {:error, %ValidationError{}} =
               BaseAgent.run(tool_agent(~s({"action": "delete_everything"})), %{
                 chat_message: "x"
               })
    end
  end
end
