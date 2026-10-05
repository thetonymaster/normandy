defmodule Normandy.Agents.ModelProtocolTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, Model}
  alias Normandy.LLM.{Call, Request, Response}
  alias Normandy.LLMError

  defmodule OneXClient do
    @moduledoc "A client still written for 1.x: converse/3 returns the bare struct."
    defstruct []

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts), do: request.response_model

      def stream(_client, _request, _opts),
        do: {:error, LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp request(response_model \\ %BaseAgentOutputSchema{}) do
    %Request{
      model: "m",
      messages: [%Normandy.Components.Message{role: "user", content: "hi"}],
      max_tokens: 16_000,
      response_model: response_model
    }
  end

  test "the protocol has exactly converse/3 and stream/3" do
    assert Enum.sort(Model.__protocol__(:functions)) == [converse: 3, stream: 3]
  end

  test "Call.converse/3 passes an {:ok, %Response{}} through" do
    client = %Normandy.Test.StubClient{}

    assert {:ok, %Response{content: %BaseAgentOutputSchema{}}} =
             Call.converse(client, request(), [])
  end

  test "Call.converse/3 raises naming the impl, the expected shape and what came back" do
    message =
      assert_raise ArgumentError, fn -> Call.converse(%OneXClient{}, request(), []) end

    assert Exception.message(message) =~ "OneXClient"
    assert Exception.message(message) =~ "{:ok, %Normandy.LLM.Response{}}"
    assert Exception.message(message) =~ "Normandy.Agents.BaseAgentOutputSchema"
  end

  test "a 1.x-style client fails run!/2 with the ArgumentError, not a MatchError" do
    agent = BaseAgent.init(%{client: %OneXClient{}, model: "m"})

    assert_raise ArgumentError, ~r/must return \{:ok, %Normandy.LLM.Response\{\}\}/, fn ->
      BaseAgent.run!(agent, %{chat_message: "hi"})
    end
  end

  test "streaming with a client that can't stream raises the client's :unsupported error" do
    agent = BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})

    assert %LLMError{type: :unsupported, retryable?: false} =
             assert_raise(LLMError, fn ->
               BaseAgent.stream_response(agent, %{chat_message: "hi"}, fn _, _ -> :ok end)
             end)
  end

  test "the default max_tokens reaches the request" do
    client = %Normandy.Test.StubClient{notify: self()}
    agent = BaseAgent.init(%{client: client, model: "m"})
    BaseAgent.run!(agent, %{chat_message: "hi"})

    assert_receive {:converse, %Request{max_tokens: 16_000, system: system, messages: messages},
                    _opts}

    assert is_binary(system)
    refute Enum.any?(messages, &(&1.role == "system"))
  end
end
