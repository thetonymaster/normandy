defmodule Normandy.Support.Tool do
  use Normandy.Schema
  alias Normandy.IOTest

  defimpl Normandy.Tools.BaseTool, for: __MODULE__ do
    def tool_name(_config), do: __MODULE__ |> to_string()
    def tool_description(_config), do: "support mockup tool"
    def run(_config), do: %IOTest{}
  end
end
