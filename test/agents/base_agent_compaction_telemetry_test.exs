defmodule Normandy.Agents.BaseAgentCompactionTelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
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
      def completitions(_client, _model, _temperature, _max_tokens, _messages, rm), do: rm

      def converse(_client, _model, _temperature, _max_tokens, _messages, rm, _opts \\ []),
        do: rm

      def stream_converse(client, _model, _temperature, _max_tokens, _messages, _rm, _opts) do
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
      name: "compacting-agent",
      behaviours: %Config{compactor: {StubCompactor, [max_tokens: 1_000, meta: meta]}}
    })
  end

  setup do
    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :compaction]])
    on_exit(fn -> :telemetry.detach(ref) end)
    %{ref: ref}
  end

  test "a compaction that fired reports token counts and strategy", %{ref: ref} do
    meta = %{
      compacted: true,
      tokens_before: 900,
      tokens_after: 300,
      tokens_removed: 600,
      strategy: :summarize
    }

    BaseAgent.compact_turn_memory(agent(meta), %Normandy.Agents.Turn.State{}, %{
      iterations_left: 3
    })

    assert_receive {[:normandy, :agent, :compaction], ^ref, measurements, metadata}
    assert measurements == %{tokens_before: 900, tokens_after: 300, tokens_removed: 600}

    assert metadata == %{
             agent_name: "compacting-agent",
             model: "m",
             strategy: :summarize,
             compacted: true,
             error: nil,
             reason: nil
           }
  end

  test "a compactor that failed or had no window says why in the event", %{ref: ref} do
    BaseAgent.compact_turn_memory(
      agent(%{compacted: false, error: {:summarize_failed, :timeout}}),
      %Normandy.Agents.Turn.State{},
      %{iterations_left: 3}
    )

    assert_receive {[:normandy, :agent, :compaction], ^ref, _,
                    %{error: {:summarize_failed, :timeout}}}

    BaseAgent.compact_turn_memory(
      agent(%{compacted: false, reason: :no_window}),
      %Normandy.Agents.Turn.State{},
      %{iterations_left: 3}
    )

    assert_receive {[:normandy, :agent, :compaction], ^ref, _, %{reason: :no_window}}
  end

  test "a chat turn with no tool calls runs the compactor before calling the model", %{ref: ref} do
    {_agent, _response} = BaseAgent.run(agent(%{compacted: false}), "hello")

    assert_receive {[:normandy, :agent, :compaction], ^ref, _measurements, %{compacted: false}}
  end

  test "a streamed turn runs the compactor before its first stream call", %{ref: ref} do
    config = agent(%{compacted: false}, %NotifyingStreamClient{notify: self()})

    {_config, _response} = BaseAgent.stream_response(config, "hello", fn _, _ -> :ok end)

    assert {:messages, [first | _]} = Process.info(self(), :messages)
    assert {[:normandy, :agent, :compaction], ^ref, _, _} = first
    assert_received :llm_called
  end

  test "a compactor run that did not compact is still observable", %{ref: ref} do
    BaseAgent.compact_turn_memory(agent(%{compacted: false}), %Normandy.Agents.Turn.State{}, %{
      iterations_left: 3
    })

    assert_receive {[:normandy, :agent, :compaction], ^ref, measurements, metadata}
    assert measurements == %{}
    assert metadata.compacted == false
    assert metadata.strategy == nil
  end
end
