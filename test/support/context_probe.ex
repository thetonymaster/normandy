defmodule Normandy.Test.ContextProbe do
  @moduledoc """
  A tool for tests that reports its context: it sends `{:probe_ctx, ctx}` to `:notify`
  (when set) and returns `{:ok, "ns=<inspect of :memory_namespace>"}`. Its input schema is
  open (`additionalProperties: true`), so a hook may rewrite its input freely.
  """
  use Normandy.Tool, description: "context probe"

  alias Normandy.Tools.Context

  defstruct name: "probe", notify: nil

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{}, additionalProperties: true}

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{} = ctx) do
    if tool.notify, do: send(tool.notify, {:probe_ctx, ctx})
    {:ok, "ns=" <> inspect(Map.get(ctx.values, :memory_namespace))}
  end
end
