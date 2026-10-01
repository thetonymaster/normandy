defmodule Normandy.Test.LazyTool do
  @moduledoc false
  # Referenced only by Normandy.Agents.LazyModuleTest, which unloads it to act
  # like a module a fresh node has not loaded yet.
  use Normandy.Tools.SchemaBaseTool

  tool_schema "lazy_tool", "a tool whose module may not be loaded" do
    field(:operation, :string, required: true, enum: ["add"])
  end

  def execute(%__MODULE__{}), do: {:ok, "ran"}
end

defmodule Normandy.Test.LazyInput do
  @moduledoc false
  # See Normandy.Test.LazyTool.
  use Normandy.Schema

  io_schema "input whose module may not be loaded" do
    field(:query, :string, description: "query", required: true)
  end
end
