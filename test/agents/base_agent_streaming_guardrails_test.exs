defmodule Normandy.Agents.BaseAgentStreamingGuardrailsTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.ForbiddenSubstrings

  # Streaming mock that yields events lazily so Enum.reduce_while can halt
  # mid-stream. Matches the real Claudio adapter's Stream.map behaviour where
  # the caller-supplied callback fires as events flow, not eagerly up-front.
  defmodule LazyStreamClient do
    use Normandy.Schema

    schema do
      field(:text_chunks, :map, default: %{chunks: ["Hello ", "world"]})
    end

    defimpl Normandy.Agents.Model do
      def completitions(_c, _m, _t, _mt, _msgs, rm), do: rm
      def converse(_c, _m, _t, _mt, _msgs, rm, _opts), do: rm

      def stream_converse(client, _model, _temp, _max_tokens, _messages, _rm, opts) do
        callback = Keyword.get(opts, :callback)
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

        lazy_stream =
          Stream.map(events, fn event ->
            if callback do
              case event do
                %{
                  type: "content_block_delta",
                  delta: %{"type" => "text_delta", "text" => text}
                } ->
                  callback.(:text_delta, text)

                %{type: "message_start", message: msg} ->
                  callback.(:message_start, msg)

                %{type: "message_stop"} ->
                  callback.(:message_stop, %{})

                _ ->
                  :ok
              end
            end

            event
          end)

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
      def completitions(_c, _m, _t, _mt, _msgs, rm), do: rm
      def converse(_c, _m, _t, _mt, _msgs, rm, _opts), do: rm

      def stream_converse(client, _model, _temp, _max_tokens, _messages, _rm, opts) do
        callback = Keyword.get(opts, :callback)
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

        lazy_stream =
          Stream.map(events, fn event ->
            if callback do
              case event do
                %{
                  type: "content_block_delta",
                  delta: %{"type" => "text_delta", "text" => text}
                } ->
                  callback.(:text_delta, text)

                _ ->
                  :ok
              end
            end

            event
          end)

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

  defp collect_callback do
    parent = self()
    {fn type, data -> send(parent, {:cb, type, data}) end, parent}
  end

  describe "accumulate mode (default)" do
    test "no violation → :guardrail_violations is empty and response returned" do
      agent = base_config([])
      {cb, _} = collect_callback()

      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert Map.get(response, :guardrail_violations) == []
      assert is_list(response.content)
    end

    test "violation → warning emitted, telemetry fires, response carries violations" do
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
        fn _event, measurements, metadata, _ ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

      {cb, _} = collect_callback()

      {_agent, response} =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          result = BaseAgent.stream_response(agent, nil, cb)
          send(self(), {:result, result})
        end)
        |> then(fn _io ->
          receive do
            {:result, r} -> r
          after
            100 -> flunk("no result captured")
          end
        end)

      assert [violation | _] = response.guardrail_violations
      assert violation.constraint == :forbidden_substring

      assert_received {:telemetry, %{count: 1}, metadata}
      assert metadata.streaming == true
      assert metadata.mode == :accumulate
      assert metadata.stage == :output

      assert_received {:cb, :guardrail_violation, payload}
      assert payload.stage == :output
      assert payload.mode == :accumulate

      :telemetry.detach("test-accumulate-#{inspect(ref)}")
    end

    test "shape parity: returns {config, response} and response has expected keys" do
      agent = base_config([])
      {cb, _} = collect_callback()

      {updated_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert %Normandy.Agents.BaseAgentConfig{} = updated_agent
      assert Map.has_key?(response, :content)
      assert Map.has_key?(response, :guardrail_violations)
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

      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert response.guardrail_violations == []
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
        fn _event, measurements, metadata, _ ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

      {cb, _} = collect_callback()

      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert [violation | _] = response.guardrail_violations
      assert violation.constraint == :forbidden_substring

      assert_received {:telemetry, %{count: 1}, metadata}
      assert metadata.streaming == true
      assert metadata.mode == :incremental

      assert_received {:cb, :guardrail_violation, payload}
      assert payload.mode == :incremental

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
      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert response.guardrail_violations == []
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
      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert [violation | _] = response.guardrail_violations
      assert violation.constraint == :forbidden_substring
      assert_received {:cb, :guardrail_violation, _payload}
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
      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert [violation | _] = response.guardrail_violations
      assert violation.constraint == :forbidden_substring
      assert_received {:cb, :guardrail_violation, _payload}
    end

    test "violation strips partial tool_use content blocks from response" do
      # Stream emits a partial tool_use content block BEFORE the text delta
      # that triggers the violation. On halt, strip_partial_tool_use should
      # remove the tool_use so the caller can't execute a tool a halted
      # stream was about to invoke.
      agent =
        BaseAgent.init(%{
          client: %ToolUseStreamClient{},
          model: "claude-3",
          temperature: 0.0,
          output_guardrails: [{ForbiddenSubstrings, terms: ["badword"]}],
          output_guardrails_streaming_mode: :incremental,
          output_guardrails_chunk_size: 5
        })

      {cb, _} = collect_callback()
      {_agent, response} = BaseAgent.stream_response(agent, nil, cb)

      assert [_ | _] = response.guardrail_violations

      refute Enum.any?(response.content, fn
               %{"type" => "tool_use"} -> true
               _ -> false
             end)
    end
  end

  describe "init/1 config validation" do
    test "raises on invalid streaming_mode" do
      assert_raise ArgumentError, ~r/:accumulate or :incremental/, fn ->
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
