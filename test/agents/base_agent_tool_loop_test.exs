defmodule NormandyTest.Agents.BaseAgentToolLoopTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, ToolCallResponse}
  alias Normandy.Components.{ToolCall, AgentMemory}
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  defmodule MockToolCallClient do
    @moduledoc """
    Mock client that simulates an LLM that can make tool calls.
    """
    use Normandy.Schema

    schema do
      field(:tool_call_count, :integer, default: 0)
      field(:final_response, :string, default: "Task completed")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(
            config,
            _model,
            _temperature,
            _max_tokens,
            messages,
            response_model,
            _opts \\ []
          ) do
        # Count tool messages in history to determine if we should make tool calls
        tool_message_count =
          Enum.count(messages, fn msg ->
            msg.role == "tool"
          end)

        cond do
          # First call - no tools executed yet, request a tool call
          tool_message_count == 0 and config.tool_call_count == 0 ->
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{
                  id: "call_1",
                  name: "calculator",
                  input: %{operation: "add", a: 5, b: 3}
                }
              ]
            }

          # Tool has been executed, return final response
          tool_message_count > 0 ->
            %ToolCallResponse{
              content: config.final_response,
              tool_calls: []
            }

          # Fallback
          true ->
            response_model
        end
      end
    end
  end

  describe "BaseAgent.run_with_tools/2" do
    setup do
      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      config = %{
        client: %MockToolCallClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      {:ok, agent: agent}
    end

    test "executes tool and returns final response", %{agent: agent} do
      user_input = %{text: "What is 5 + 3?"}
      {updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      # Should return the final output schema (BaseAgentOutputSchema)
      assert %BaseAgentOutputSchema{} = response
      assert response.chat_message == "Task completed"

      # Memory should contain user message, assistant tool call, tool result, and final response
      history = AgentMemory.history(updated_agent.memory)
      assert length(history) >= 3
    end

    test "respects max_tool_iterations limit" do
      # Create agent with very low max iterations
      config = %{
        client: %MockToolCallClient{final_response: "Stopped due to limit"},
        model: "test-model",
        temperature: 0.7,
        tool_registry: Registry.new([%Calculator{operation: "add", a: 0, b: 0}]),
        max_tool_iterations: 0
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "Calculate something"}

      {_updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      # Should still return a response even with 0 iterations
      assert response != nil
    end

    test "works without user_input (continuing conversation)" do
      # First run with user input
      calc = %Calculator{operation: "multiply", a: 0, b: 0}
      registry = Registry.new([calc])

      config = %{
        client: %MockToolCallClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "First message"}

      {agent, _response} = BaseAgent.run_with_tools(agent, user_input)

      # Now run without user input
      {updated_agent, response} = BaseAgent.run_with_tools(agent, nil)

      assert response != nil
      assert updated_agent.memory != nil
    end
  end

  describe "Tool execution error handling" do
    defmodule BrokenCalculator do
      defstruct [:operation, :a, :b]

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "broken_calculator"
        def tool_description(_), do: "A calculator that always fails"

        def input_schema(_) do
          %{type: "object"}
        end

        def run(_) do
          {:error, "Calculator is broken"}
        end
      end
    end

    test "handles tool execution errors gracefully" do
      broken_calc = %BrokenCalculator{operation: "add", a: 1, b: 2}
      registry = Registry.new([broken_calc])

      config = %{
        client: %MockToolCallClient{final_response: "Handled error"},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "Test error"}

      # Should not crash, should handle error
      {_updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)

      assert response != nil
      assert response.chat_message == "Handled error"
    end
  end

  describe "unwrap_tool_task_result!/1" do
    # Direct unit tests for the helper. We can't exercise it via a real
    # tool raise because `Task.async_stream/3` (linked variant) propagates
    # worker raises to the caller through the process link *before* the
    # stream yields, so for raises the unwrap path is unreachable. The
    # helper still matters for `{:exit, _}` reasons that DO surface
    # through the stream (timeouts via `on_timeout: :kill_task`,
    # deliberate `exit/1` from wrapper code).

    test "passes through {:ok, result} unchanged" do
      result = %{some: "value"}
      assert BaseAgent.unwrap_tool_task_result!({:ok, result}) == result
    end

    test "re-raises {:exit, {exception, stacktrace}} with original stack" do
      stacktrace = [
        {SomeMod, :some_fun, 1, [file: ~c"some_file.ex", line: 42]}
      ]

      err =
        assert_raise RuntimeError, "boom", fn ->
          BaseAgent.unwrap_tool_task_result!(
            {:exit, {%RuntimeError{message: "boom"}, stacktrace}}
          )
        end

      assert err.message == "boom"
    end

    test "exits cleanly with the original reason on {:exit, reason}" do
      Process.flag(:trap_exit, true)

      pid =
        spawn_link(fn ->
          BaseAgent.unwrap_tool_task_result!({:exit, :timeout})
        end)

      assert_receive {:EXIT, ^pid, :timeout}, 500
    end
  end

  describe "Tool input atom-table hardening" do
    # Mock client that emits a tool_use whose `input` map mixes valid binary
    # keys with a canary key (one that does NOT correspond to any field on
    # the tool). This exercises the binary-key path of the per-call helper
    # `normalize_tool_field_key/2` — the path that previously called
    # `String.to_atom/1` and could be coerced into exhausting the BEAM atom
    # table by attacker-controlled LLM input.
    defmodule MockHostileToolClient do
      use Normandy.Schema

      schema do
        field(:canary_key, :string)
      end

      defimpl Normandy.Agents.Model do
        def completitions(_, _, _, _, _, response_model), do: response_model

        def converse(
              config,
              _model,
              _temperature,
              _max_tokens,
              messages,
              _response_model,
              _opts \\ []
            ) do
          tool_message_count =
            Enum.count(messages, fn msg -> msg.role == "tool" end)

          if tool_message_count == 0 do
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{
                  id: "call_canary",
                  name: "calculator",
                  input: %{
                    "operation" => "add",
                    "a" => 5,
                    "b" => 3,
                    config.canary_key => "should_be_dropped"
                  }
                }
              ]
            }
          else
            %ToolCallResponse{content: "ok", tool_calls: []}
          end
        end
      end
    end

    test "drops unknown input keys without registering them as atoms" do
      # Build a canary string at runtime so its bytes are unique per test
      # run. If any atom equal to this string exists in the BEAM atom table
      # before the test runs, the assertion below would falsely pass — the
      # initial assert_raise pins the precondition.
      canary = "atom_table_canary_#{:erlang.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end

      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      config = %{
        client: %MockHostileToolClient{canary_key: canary},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5
      }

      agent = BaseAgent.init(config)
      user_input = %{text: "trigger hostile tool call"}

      {_updated_agent, response} = BaseAgent.run_with_tools(agent, user_input)
      assert response != nil

      # If the legacy `String.to_atom/1` reducer had still been in place,
      # the canary key would now be a registered atom and this call would
      # succeed. With `normalize_tool_field_key/2` the unknown key is
      # silently dropped before any atom-table interaction.
      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end
    end
  end

  describe "max_tool_concurrency parallel execution" do
    # Tool that sleeps for the configured duration before returning. Used as
    # a deterministic stand-in for I/O-bound tools (HTTP, DB, search) so the
    # parallelism speedup shows up as a wall-clock difference.
    defmodule SleepyTool do
      use Normandy.Schema

      schema do
        field(:sleep_ms, :integer, default: 200)
        field(:label, :string, default: "")
      end

      defimpl Normandy.Tools.BaseTool do
        def tool_name(_), do: "sleepy"
        def tool_description(_), do: "Sleeps then returns its label."

        def input_schema(_) do
          %{
            type: "object",
            properties: %{
              sleep_ms: %{type: "integer"},
              label: %{type: "string"}
            }
          }
        end

        def run(%{sleep_ms: ms, label: label}) do
          :timer.sleep(ms)
          {:ok, label}
        end
      end
    end

    # Mock client that emits N parallel tool_use blocks pointing at the
    # SleepyTool, then a final response once all results have streamed back.
    defmodule MockSleepyClient do
      use Normandy.Schema

      schema do
        field(:n, :integer, default: 3)
        field(:sleep_ms, :integer, default: 200)
      end

      defimpl Normandy.Agents.Model do
        def completitions(_, _, _, _, _, response_model), do: response_model

        def converse(
              config,
              _model,
              _temperature,
              _max_tokens,
              messages,
              _response_model,
              _opts \\ []
            ) do
          tool_messages = Enum.count(messages, &(&1.role == "tool"))

          if tool_messages == 0 do
            tool_calls =
              for i <- 1..config.n do
                %ToolCall{
                  id: "call_#{i}",
                  name: "sleepy",
                  input: %{sleep_ms: config.sleep_ms, label: "tool_#{i}"}
                }
              end

            %ToolCallResponse{content: nil, tool_calls: tool_calls}
          else
            %ToolCallResponse{content: "done", tool_calls: []}
          end
        end
      end
    end

    defp run_with_concurrency(concurrency, n, sleep_ms) do
      registry = Registry.new([%SleepyTool{}])

      config = %{
        client: %MockSleepyClient{n: n, sleep_ms: sleep_ms},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5,
        max_tool_concurrency: concurrency
      }

      agent = BaseAgent.init(config)

      {elapsed_us, {_agent, response}} =
        :timer.tc(fn -> BaseAgent.run_with_tools(agent, %{text: "fan out"}) end)

      {elapsed_us, response}
    end

    test "max_tool_concurrency: 1 runs tools sequentially" do
      # 3 tools × 100 ms each = ~300 ms minimum, sequential
      {elapsed_us, response} = run_with_concurrency(1, 3, 100)

      assert response != nil

      assert div(elapsed_us, 1000) >= 300,
             "expected sequential >= 300ms, got #{div(elapsed_us, 1000)}ms"
    end

    test "max_tool_concurrency: 3 runs tools in parallel (faster than sequential)" do
      # Compare parallel vs sequential on the SAME runner so the assertion is
      # self-calibrating: a slow CI machine pushes both numbers up together.
      # 3 × 100 ms sequential ≈ 300 ms; 3 × 100 ms parallel ≈ 100 ms ideal,
      # but CI runners eat ~75 ms per `Task.async_stream` batch (OTel ctx +
      # task spawn + memory updates), pushing parallel to ~175 ms. Require at
      # least a 1.5× speedup (`par × 3 < seq × 2`, i.e. par ≤ 2/3 of seq) —
      # without overlap, 3 sleeps can't possibly compress that much, so a
      # passing result still proves parallelism happened.
      {seq_us, _} = run_with_concurrency(1, 3, 100)
      {par_us, response} = run_with_concurrency(3, 3, 100)

      assert response != nil

      assert par_us * 3 < seq_us * 2,
             "expected parallel ≤ 2/3 of sequential (≥ 1.5× speedup), " <>
               "got par=#{div(par_us, 1000)}ms seq=#{div(seq_us, 1000)}ms"
    end

    test "tool results stay in LLM-supplied call order under parallelism" do
      registry = Registry.new([%SleepyTool{}])

      config = %{
        client: %MockSleepyClient{n: 3, sleep_ms: 50},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5,
        max_tool_concurrency: 3
      }

      agent = BaseAgent.init(config)
      {agent, _response} = BaseAgent.run_with_tools(agent, %{text: "fan out"})

      # `memory.history` is stored LIFO ([newest | rest]) for O(1) prepends.
      # Reverse to get chronological order before filtering.
      tool_msgs =
        agent.memory.history
        |> Enum.reverse()
        |> Enum.filter(&(&1.role == "tool"))

      assert length(tool_msgs) == 3

      labels = Enum.map(tool_msgs, fn msg -> msg.content.output end)

      assert labels == ["tool_1", "tool_2", "tool_3"],
             "expected ordered labels, got #{inspect(labels)}"
    end
  end
end
