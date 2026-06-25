defmodule AutoresumeDemo.SimClient do
  @moduledoc """
  Deterministic LLM stand-in implementing Normandy.Agents.Model for
  DEMO_MODE=simulated. Drives a multi-step tool loop by counting prior assistant
  turns in the conversation: emits a research_step tool call until `total_steps`
  steps have run, then finalizes with plain content. A per-call sleep makes turns
  slow enough to kill a node mid-flight.
  """
  defstruct topic: "distributed systems", total_steps: 6, step_delay_ms: 1500

  defimpl Normandy.Agents.Model do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.ToolCall

    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _model, _temp, _max_tokens, messages, _response_model, _opts \\ []) do
      if client.step_delay_ms > 0, do: Process.sleep(client.step_delay_ms)

      done = count_assistant(messages)

      resp =
        if done < client.total_steps do
          step = done + 1

          %ToolCallResponse{
            content: "Researching #{client.topic} (step #{step}/#{client.total_steps})…",
            tool_calls: [
              %ToolCall{
                id: "sim-#{System.unique_integer([:positive])}",
                name: "research_step",
                input: %{"topic" => client.topic, "n" => step}
              }
            ]
          }
        else
          %ToolCallResponse{
            content:
              "Done researching #{client.topic}: synthesized #{client.total_steps} findings.",
            tool_calls: []
          }
        end

      {resp, nil}
    end

    defp count_assistant(messages),
      do: Enum.count(messages, fn m -> role_of(m) == "assistant" end)

    defp role_of(%{role: r}), do: to_string(r)
    defp role_of(%{"role" => r}), do: to_string(r)
    defp role_of(_), do: nil
  end
end
