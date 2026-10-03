defmodule Normandy.Test.ContextProbe do
  @moduledoc """
  A contextual tool for tests. With context it sends `{:probe_ctx, ctx}` to
  `:notify` (when set) and returns `{:ok, "ns=<inspect of :memory_namespace>"}`;
  run without context (`BaseTool.run/1`) it returns the "requires tool context" error.
  """
  defstruct name: "probe", notify: nil

  defimpl Normandy.Tools.BaseTool do
    def tool_name(tool), do: tool.name
    def tool_description(_tool), do: "context probe"
    def input_schema(_tool), do: %{type: "object", properties: %{}}

    def run(tool),
      do:
        {:error,
         "#{tool.name} requires tool context; it was called outside the dispatch pipeline"}
  end

  defimpl Normandy.Tools.ContextualTool do
    def run(tool, ctx) do
      if tool.notify, do: send(tool.notify, {:probe_ctx, ctx})
      {:ok, "ns=" <> inspect(Map.get(ctx.values, :memory_namespace))}
    end
  end
end
