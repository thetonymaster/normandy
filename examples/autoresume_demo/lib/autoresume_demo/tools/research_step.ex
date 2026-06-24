defmodule AutoresumeDemo.Tools.ResearchStep do
  @moduledoc "Lightweight tool an agent calls once per research step."
  defstruct [:topic, :n]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "research_step"

    def tool_description(_),
      do:
        "Record one research step on the topic and return a short finding. " <>
          "Call once per step with the next step number n."

    def input_schema(_) do
      %{
        "type" => "object",
        "properties" => %{
          "topic" => %{"type" => "string", "description" => "The research topic"},
          "n" => %{"type" => "integer", "description" => "The step number (1-based)"}
        },
        "required" => ["topic", "n"]
      }
    end

    def run(%{topic: topic, n: n}) when not is_nil(topic) and not is_nil(n) do
      {:ok, %{"step" => n, "finding" => "Finding ##{n} about #{topic}."}}
    end

    def run(params) when is_map(params) do
      topic = Map.get(params, :topic) || Map.get(params, "topic") || "unknown"
      n = Map.get(params, :n) || Map.get(params, "n") || 0
      {:ok, %{"step" => n, "finding" => "Finding ##{n} about #{topic}."}}
    end
  end
end
