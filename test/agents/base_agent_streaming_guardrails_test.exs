defmodule Normandy.Agents.BaseAgentStreamingGuardrailsTest do
  # async: false — the guardrail telemetry handlers are global and forward every
  # violation event to the test process.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings
  alias Normandy.Test.FakeTool

  # Streaming mock that yields events lazily so Enum.reduce_while can halt
  # mid-stream. Matches the real Claudio adapter's Stream.map behaviour: Normandy
  # delivers each event to the callback as it flows, not eagerly up-front.
  defmodule LazyStreamClient do
    use Normandy.Schema

    schema do
      field(:text_chunks, :map, default: %{chunks: ["Hello ", "world"]})
    end

    defimpl Normandy.Agents.Model do
      def converse(_c, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      def stream(client, _request, _opts) do
        chunks = client.text_chunks.chunks

        events =
          [
            %{
              type: "message_start",
              message: %{"id" => "msg_1", "model" => "claude-3", "role" => "assistant"}
            },
            %{
              type: "content_block_start",
              content_block: %{"type" => "text", "text" => ""},
              index: 0
            }
          ] ++
            Enum.map(chunks, fn chunk ->
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => chunk},
                index: 0
              }
            end) ++
            [
              %{
                type: "message_delta",
                delta: %{"stop_reason" => "end_turn"},
                usage: %{"output_tokens" => length(chunks)}
              },
              %{type: "message_stop"}
            ]

        # Lazy, so incremental guards can halt mid-stream.
        lazy_stream = Stream.map(events, & &1)

        {:ok, lazy_stream}
      end
    end
  end

  # Streaming mock that emits a partial tool_use content block alongside
  # text deltas. Used to verify that mid-stream halts strip unfinished
  # tool_use blocks from the returned response.
  defmodule ToolUseStreamClient do
    use Normandy.Schema

    schema do
      field(:text_chunks, :map, default: %{chunks: ["BADWORD here"]})
    end

    defimpl Normandy.Agents.Model do
      def converse(_c, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      def stream(client, _request, _opts) do
        chunks = client.text_chunks.chunks

        events =
          [
            %{
              type: "message_start",
              message: %{"id" => "msg_1", "model" => "claude-3", "role" => "assistant"}
            },
            %{
              type: "content_block_start",
              content_block: %{"type" => "text", "text" => ""},
              index: 0
            },
            %{
              type: "content_block_start",
              content_block: %{
                "type" => "tool_use",
                "id" => "tu_1",
                "name" => "calculator",
                "input" => ""
              },
              index: 1
            }
          ] ++
            Enum.map(chunks, fn chunk ->
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => chunk},
                index: 0
              }
            end) ++
            [
              %{
                type: "message_delta",
                delta: %{"stop_reason" => "tool_use"},
                usage: %{"output_tokens" => length(chunks)}
              },
              %{type: "message_stop"}
            ]

        # Lazy, so incremental guards can halt mid-stream.
        lazy_stream = Stream.map(events, & &1)

        {:ok, lazy_stream}
      end
    end
  end

  defp base_config(guards, extra \\ []) do
    client = %LazyStreamClient{}

    config =
      Map.merge(
        %{
          client: client,
          model: "claude-3",
          temperature: 0.5,
          output_guardrails: guards
        },
        Map.new(extra)
      )

    BaseAgent.init(config)
  end

  def handle_violation(_event, measurements, metadata, parent),
    do: send(parent, {:telemetry, measurements, metadata})

  defp collect_callback do
    parent = self()
    {fn %StreamEvent{type: type, data: data} -> send(parent, {:cb, type, data}) end, parent}
  end

  describe "accumulate mode (default)" do
    test "no violation → no :guardrail_violation event and the answer returned" do
      agent = base_config([{ForbiddenSubstrings, terms: ["badword"]}])
      {cb, _} = collect_callback()

      {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)

      assert %BaseAgentOutputSchema{chat_message: "Hello world"} = response
      refute_received {:cb, :guardrail_violation, _}
    end

    test "violation → warning logged without the output, telemetry fires, event delivered" do
      client = %LazyStreamClient{text_chunks: %{chunks: ["ok ", "BADWORD here"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}]
        })

      ref = :erlang.make_ref()
      parent = self()

      :telemetry.attach(
        "test-accumulate-#{inspect(ref)}",
        [:normandy, :agent, :guardrail, :violation],
        &__MODULE__.handle_violation/4,
        parent
      )

      {cb, _} = collect_callback()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)
          # Reported, not blocked: the answer is returned.
          assert response.chat_message == "ok BADWORD here"
        end)

      assert log =~ "normandy agent streaming output guardrail violation"
      refute log =~ "BADWORD"

      assert_received {:telemetry, %{count: 1}, metadata}
      assert metadata.streaming == true
      assert metadata.mode == :accumulate
      assert metadata.stage == :output

      assert_received {:cb, :guardrail_violation, payload}
      assert payload.stage == :output
      assert payload.mode == :accumulate
      assert [violation | _] = payload.violations
      assert violation.constraint == :forbidden_substring

      :telemetry.detach("test-accumulate-#{inspect(ref)}")
    end

    test "violation metadata is not persisted into assistant memory" do
      client = %LazyStreamClient{text_chunks: %{chunks: ["ok ", "BADWORD here"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}]
        })

      {cb, _} = collect_callback()

      {:ok, updated_agent, _response} = BaseAgent.stream(agent, nil, cb)

      # The caller still gets the violations, through the callback.
      assert_received {:cb, :guardrail_violation, %{violations: [_ | _]}}

      # But assistant-role memory entries must not carry the violation metadata,
      # otherwise matched terms/paths feed back into the next LLM call.
      assistant_entries =
        AgentMemory.messages(updated_agent.memory)
        |> Enum.filter(&(&1.role == "assistant"))

      assert assistant_entries != []

      for %{content: content} <- assistant_entries do
        refute is_map(content) and Map.has_key?(content, :guardrail_violations),
               "assistant memory must not contain :guardrail_violations, got: #{inspect(content)}"
      end
    end

    test "shape parity: returns {:ok, config, output} like run/3" do
      agent = base_config([])
      {cb, _} = collect_callback()

      {:ok, updated_agent, response} = BaseAgent.stream(agent, nil, cb)

      assert %Normandy.Agents.BaseAgentConfig{} = updated_agent
      assert %BaseAgentOutputSchema{} = response
      refute Map.has_key?(response, :guardrail_violations)
    end
  end

  describe "incremental mode" do
    test "no violation → stream consumes fully, response clean" do
      client = %LazyStreamClient{text_chunks: %{chunks: [String.duplicate("a", 50), "safe end"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 20
        })

      {cb, _} = collect_callback()

      {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)

      assert response.chat_message == String.duplicate("a", 50) <> "safe end"
      refute_received {:cb, :guardrail_violation, _}
    end

    test "violation halts stream, callback receives :guardrail_violation, telemetry fires" do
      # Chunks are designed so the violation appears in the second delta. With
      # chunk_size=10 and first delta 12 bytes, the first check already sees
      # the forbidden term.
      client = %LazyStreamClient{text_chunks: %{chunks: ["Hello BADWORD ", "tail content"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 10
        })

      ref = :erlang.make_ref()
      parent = self()

      :telemetry.attach(
        "test-incremental-#{inspect(ref)}",
        [:normandy, :agent, :guardrail, :violation],
        &__MODULE__.handle_violation/4,
        parent
      )

      {cb, _} = collect_callback()

      {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)

      # Halted: the answer holds the text streamed up to the violation.
      assert response.chat_message == "Hello BADWORD "

      assert_received {:telemetry, %{count: 1}, metadata}
      assert metadata.streaming == true
      assert metadata.mode == :incremental

      assert_received {:cb, :guardrail_violation, payload}
      assert payload.mode == :incremental
      assert [violation | _] = payload.violations
      assert violation.constraint == :forbidden_substring

      # The second chunk's text should NOT have been emitted to the callback —
      # halt fires before we process it.
      text_deltas =
        Stream.repeatedly(fn ->
          receive do
            {:cb, :text_delta, t} -> t
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      refute Enum.any?(text_deltas, &String.contains?(&1, "tail content"))

      :telemetry.detach("test-incremental-#{inspect(ref)}")
    end

    test "does not trigger on chunk-size boundary when guards pass" do
      # 25 chars of safe text with chunk_size=10 triggers 2+ guard checks.
      client = %LazyStreamClient{text_chunks: %{chunks: [String.duplicate("a", 25)]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["zzz"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 10
        })

      {cb, _} = collect_callback()
      {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)

      assert response.chat_message == String.duplicate("a", 25)
      refute_received {:cb, :guardrail_violation, _}
    end

    test "tail-of-stream check catches violations when total output < chunk_size" do
      # Total output is 14 bytes but chunk_size is 100 — without a tail pass,
      # guards would never run on short outputs and forbidden terms would
      # slip through.
      client = %LazyStreamClient{text_chunks: %{chunks: ["Hello ", "BADWORD"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 100
        })

      {cb, _} = collect_callback()
      {:ok, _agent, _response} = BaseAgent.stream(agent, nil, cb)

      assert_received {:cb, :guardrail_violation, %{violations: [violation | _]}}
      assert violation.constraint == :forbidden_substring
    end

    test "tail-of-stream check catches violations after a prior successful check" do
      # chunk_size=10: first delta crosses threshold (check passes), second
      # delta adds text with the forbidden term but doesn't re-cross threshold.
      # Without tail check, that tail content would bypass guards.
      client =
        %LazyStreamClient{text_chunks: %{chunks: [String.duplicate("a", 12), " BADWORD"]}}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 10
        })

      {cb, _} = collect_callback()
      {:ok, _agent, _response} = BaseAgent.stream(agent, nil, cb)

      assert_received {:cb, :guardrail_violation, %{violations: [violation | _]}}
      assert violation.constraint == :forbidden_substring
    end

    test "violation strips partial tool_use content blocks, so the tool never runs" do
      # Stream emits a partial tool_use content block BEFORE the text delta
      # that triggers the violation. On halt, strip_partial_tool_use should
      # remove the tool_use so the agent can't execute a tool a halted
      # stream was about to invoke.
      agent =
        %{
          client: %ToolUseStreamClient{},
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 5
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%FakeTool{name: "calculator", notify: self()})

      {cb, _} = collect_callback()
      {:ok, _agent, response} = BaseAgent.stream(agent, nil, cb)

      assert_received {:cb, :guardrail_violation, %{violations: [_ | _]}}
      refute_received {:tool_ran, "calculator"}
      refute_received {:cb, :tool_result, _}
      assert response.chat_message == "BADWORD here"
    end
  end

  describe "init/1 config validation" do
    test "raises on invalid streaming_mode" do
      assert_raise ArgumentError,
                   ~r/expected one of \[:accumulate, :incremental\], got: :bogus/,
                   fn ->
                     BaseAgent.init(%{
                       client: %LazyStreamClient{},
                       model: "claude-3",
                       temperature: 0.0,
                       output_guardrails_streaming_mode: :bogus
                     })
                   end
    end

    test "raises on non-positive chunk_size" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        BaseAgent.init(%{
          client: %LazyStreamClient{},
          model: "claude-3",
          temperature: 0.0,
          output_guardrails_chunk_size: 0
        })
      end
    end

    test "raises on non-integer chunk_size" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        BaseAgent.init(%{
          client: %LazyStreamClient{},
          model: "claude-3",
          temperature: 0.0,
          output_guardrails_chunk_size: "big"
        })
      end
    end

    test "defaults: mode = :accumulate, chunk_size = 200" do
      agent =
        BaseAgent.init(%{
          client: %LazyStreamClient{},
          model: "claude-3",
          temperature: 0.0
        })

      assert agent.output_guardrails_streaming_mode == :accumulate
      assert agent.output_guardrails_chunk_size == 200
    end
  end
end
