defmodule Normandy.Test.ReturnTool do
  @moduledoc """
  A tool for tests that returns its `:output` unchanged: `{:ok, output}`, or
  `{:error, output}` when `error: true`. It is named by `:name` (default `"big"`) and takes
  an empty object as input.
  """
  use Normandy.Tool, description: "returns its configured output"

  alias Normandy.Tools.Context

  defstruct name: "big", output: "", error: false

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{}}

  @impl Normandy.Tool
  def run(%__MODULE__{error: true, output: output}, %Context{}), do: {:error, output}
  def run(%__MODULE__{output: output}, %Context{}), do: {:ok, output}
end
