defmodule Normandy.Test.LazyToolInput do
  @moduledoc false
  # Normandy.Test.LazyTool's input schema.
  use Normandy.Schema

  io_schema "a tool whose module may not be loaded" do
    field(:operation, :string, required: true, enum: ["add"])
  end
end

defmodule Normandy.Test.LazyTool do
  @moduledoc false
  # Referenced only by Normandy.Agents.LazyModuleTest, which unloads it to act
  # like a module a fresh node has not loaded yet.
  use Normandy.Tool,
    name: "lazy_tool",
    description: "a tool whose module may not be loaded",
    input: Normandy.Test.LazyToolInput

  defstruct []

  @impl Normandy.Tool
  def run(_tool, _context), do: {:ok, "ran"}
end

defmodule Normandy.Test.LazyInput do
  @moduledoc false
  # See Normandy.Test.LazyTool.
  use Normandy.Schema

  io_schema "input whose module may not be loaded" do
    field(:query, :string, description: "query", required: true)
  end
end
