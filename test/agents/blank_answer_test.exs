defmodule Normandy.Agents.BlankAnswerTest do
  @moduledoc """
  Decision 22: an empty or whitespace-only final answer is the `:invalid_output`
  LLMError on every path, including a chat agent with no tools (whose response model
  is the output schema, so the answer is only validated, never converted).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Test.ScriptedTextClient

  @message "expected a final answer, got an empty one: the model ended its turn with no text"

  defp chat_agent(text),
    do: BaseAgent.init(%{client: %ScriptedTextClient{text: text}, model: "m", max_tokens: 64})

  for text <- ["", "  \n"] do
    @text text

    test "run/3: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      assert {:error, %LLMError{type: :invalid_output} = error} =
               BaseAgent.run(chat_agent(@text), "hi")

      assert Exception.message(error) =~ @message
    end

    test "stream/3: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      assert {:error, %LLMError{type: :invalid_output} = error} =
               BaseAgent.stream(chat_agent(@text), "hi", fn _event -> :ok end)

      assert Exception.message(error) =~ @message
    end

    test "Turn.Server: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      sid = "s-blank-#{System.unique_integer([:positive])}"

      {:ok, srv} =
        Server.start_link(
          session_id: sid,
          config: chat_agent(@text),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, %LLMError{type: :invalid_output} = error} =
               Server.run(srv, %{chat_message: "hi"})

      assert Exception.message(error) =~ @message
    end
  end

  test "a non-blank answer still succeeds on run/3 and Turn.Server" do
    assert {:ok, _config, %{chat_message: "Hello"}} = BaseAgent.run(chat_agent("Hello"), "hi")

    {:ok, srv} =
      Server.start_link(
        session_id: "s-blank-ok",
        config: chat_agent("Hello"),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %{chat_message: "Hello"}} = Server.run(srv, %{chat_message: "hi"})
  end
end
