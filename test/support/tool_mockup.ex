defmodule NormandyTest.Support.Tool do
  @moduledoc false
  use Normandy.Schema
  alias NormandyTest.IOTest

  defimpl Normandy.Tools.BaseTool, for: __MODULE__ do
    def tool_name(_config), do: __MODULE__ |> to_string()
    def tool_description(_config), do: "support mockup tool"

    def input_schema(_config) do
      %{type: "object"}
    end

    def run(_config), do: {:ok, %IOTest{}}
  end
end
