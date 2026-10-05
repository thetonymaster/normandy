defmodule Normandy.Test.FakeTool do
  @moduledoc """
  A tool for tests. It is named by `:name` (default `"weather"`), takes an optional string
  `"city"` input, and returns `"weather in <city>"` whatever its name. With `:sleep_ms`, it
  sleeps first. With `:notify`, it sends `{:tool_ran, name}` to that pid when it runs.
  """
  use Normandy.Tool, description: "fake"

  alias Normandy.Tools.Context

  defstruct name: "weather", notify: nil, sleep_ms: 0

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{city: %{type: "string"}}}

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{input: input}) do
    if tool.sleep_ms > 0, do: Process.sleep(tool.sleep_ms)
    if tool.notify, do: send(tool.notify, {:tool_ran, tool.name})
    {:ok, "weather in #{input["city"]}"}
  end
end
