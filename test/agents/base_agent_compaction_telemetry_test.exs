defmodule Normandy.Agents.BaseAgentCompactionTelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Behaviours.Config

  defmodule StubCompactor do
    @behaviour Normandy.Behaviours.Compactor
    @impl true
    def maybe_compact(acc, _ctx, opts), do: {acc, Keyword.fetch!(opts, :meta)}
  end

  # Reports each stream call to `notify`, then streams a one-word reply.
  defmodule NotifyingStreamClient do
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      def stream(client, _request, _opts) do
        send(client.notify, :llm_called)

        {:ok,
         [
           %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
           %{
             type: "content_block_start",
             content_block: %{"type" => "text", "text" => ""},
             index: 0
           },
           %{
             type: "content_block_delta",
             delta: %{"type" => "text_delta", "text" => "hi"},
             index: 0
           },
           %{type: "message_delta", delta: %{"stop_reason" => "end_turn"}, usage: %{}},
           %{type: "message_stop"}
         ]}
      end
    end
  end

  defp agent(meta, client \\ %NormandyTest.Support.ModelMockup{}) do
    BaseAgent.init(%{
      client: client,
      model: "m",
      temperature: nil,
      name: Process.get(:agent_name),
      behaviours: %Config{compactor: {StubCompactor, [context_window: 1_000, meta: meta]}}
    })
  end

  def handle_compaction(_event, measurements, metadata, {test_pid, name}) do
    if metadata.agent_name == name,
      do: send(test_pid, {:compaction, measurements, metadata})
  end

  # Every agent turn emits this event, and telemetry handlers are global, so concurrent
  # async tests' events would reach this test too. Forward only this test's agent's.
  setup do
    name = "compacting-agent-#{System.unique_integer([:positive])}"
    Process.put(:agent_name, name)
    test_pid = self()
    handler_id = {__MODULE__, name}

    :ok =
      :telemetry.attach(
        handler_id,
        [:normandy, :agent, :compaction],
        &__MODULE__.handle_compaction/4,
        {test_pid, name}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{name: name}
  end

  test "a compaction that fired reports token counts and strategy", %{name: name} do
    meta = %{
      compacted: true,
      tokens_before: 900,
      tokens_after: 300,
      tokens_removed: 600,
      strategy: :summarize
    }

    AgentHandlers.compact_turn_memory(agent(meta), %Normandy.Agents.Turn.State{}, %{
      iterations_left: 3,
      mid_round: false
    })

    assert_receive {:compaction, measurements, metadata}
    assert measurements == %{tokens_before: 900, tokens_after: 300, tokens_removed: 600}

    assert metadata == %{
             agent_name: name,
             model: "m",
             strategy: :summarize,
             compacted: true,
             mid_round: false,
             error: nil,
             reason: nil
           }
  end

  test "a compactor that failed or had no window says why in the event" do
    AgentHandlers.compact_turn_memory(
      agent(%{compacted: false, error: {:summarize_failed, :timeout}}),
      %Normandy.Agents.Turn.State{},
      %{iterations_left: 3, mid_round: false}
    )

    assert_receive {:compaction, _, %{error: {:summarize_failed, :timeout}}}

    AgentHandlers.compact_turn_memory(
      agent(%{compacted: false, reason: :no_window}),
      %Normandy.Agents.Turn.State{},
      %{iterations_left: 3, mid_round: false}
    )

    assert_receive {:compaction, _, %{reason: :no_window}}
  end

  test "a chat turn with no tool calls runs the compactor before calling the model" do
    {_agent, _response} = BaseAgent.run!(agent(%{compacted: false}), "hello")

    assert_receive {:compaction, _measurements, %{compacted: false}}
  end

  test "a streamed turn runs the compactor before its first stream call" do
    config = agent(%{compacted: false}, %NotifyingStreamClient{notify: self()})

    {:ok, _config, _response} = BaseAgent.stream(config, "hello", fn _ -> :ok end)

    assert {:messages, [first | _]} = Process.info(self(), :messages)
    assert {:compaction, _, _} = first
    assert_received :llm_called
  end

  test "a compactor run that did not compact is still observable" do
    AgentHandlers.compact_turn_memory(
      agent(%{compacted: false}),
      %Normandy.Agents.Turn.State{},
      %{
        iterations_left: 3,
        mid_round: false
      }
    )

    assert_receive {:compaction, measurements, metadata}
    assert measurements == %{}
    assert metadata.compacted == false
    assert metadata.strategy == nil
  end
end
