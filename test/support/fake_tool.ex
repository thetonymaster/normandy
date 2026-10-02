defmodule Normandy.Test.FakeTool do
  @moduledoc """
  A tool for tests. It is named by `:name` (default `"weather"`), casts a
  `"city"` input, and returns `"weather in <city>"` whatever its name. With
  `:sleep_ms`, it sleeps first. With `:notify`, it sends `{:tool_ran, name}`
  to that pid when it runs.
  """
  use Normandy.Schema

  schema do
    field(:name, :string, default: "weather")
    field(:city, :string)
    field(:notify, :any, default: nil)
    field(:sleep_ms, :integer, default: 0)
  end

  defimpl Normandy.Tools.BaseTool do
    def tool_name(tool), do: tool.name
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}

    def run(tool) do
      if tool.sleep_ms > 0, do: Process.sleep(tool.sleep_ms)
      if tool.notify, do: send(tool.notify, {:tool_ran, tool.name})
      {:ok, "weather in #{tool.city}"}
    end
  end
end
