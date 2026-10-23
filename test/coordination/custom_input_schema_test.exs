defmodule Normandy.Coordination.CustomInputSchemaTest do
  # An agent whose input schema has more than :chat_message must get the input map whole
  # from every coordinator, as BaseAgent.run/3 does.
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias Normandy.Coordination.{HierarchicalCoordinator, ParallelOrchestrator}
  alias Normandy.Coordination.SequentialOrchestrator

  defmodule TwoFieldInput do
    @moduledoc false
    use Normandy.Schema

    io_schema "chat message and a language" do
      field(:chat_message, :string, description: "message", required: true)
      field(:language, :string, description: "language")
    end
  end

  defmodule OkClient do
    @moduledoc false
    use Normandy.Schema

    schema do
    end

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: %{request.response_model | chat_message: "ok"}}}

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp agent do
    BaseAgent.init(%{client: %OkClient{}, model: "m", input_schema: %TwoFieldInput{}})
  end

  @input %{chat_message: "hi", language: "es"}

  test "Batch.Processor passes the whole input map" do
    assert {:ok, [{:ok, _}]} = Processor.process_batch(agent(), [@input])
  end

  test "a HierarchicalCoordinator manager gets the whole input map" do
    coordinator =
      HierarchicalCoordinator.new(
        manager: agent(),
        workers: [%{id: "w", agent: BaseAgent.init(%{client: %OkClient{}, model: "m"})}],
        delegation_strategy: :broadcast
      )

    assert {:ok, _} = HierarchicalCoordinator.execute(coordinator, @input)
  end

  test "Parallel and Sequential workers get the whole input map" do
    assert {:ok, %{"agent_0" => _}} = ParallelOrchestrator.execute([agent()], @input)
    assert {:ok, %{"agent_0" => _}} = SequentialOrchestrator.execute([agent()], @input)
  end
end
