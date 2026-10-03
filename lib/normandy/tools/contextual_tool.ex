defprotocol Normandy.Tools.ContextualTool do
  @moduledoc """
  Opt-in protocol for tools that need to know whom they run for.

  A contextual tool still implements `Normandy.Tools.BaseTool` (name, description, input
  schema). The executor calls `run/2` instead of `BaseTool.run/1` when it has a
  `%Normandy.Tools.Context{}`; the dispatch pipeline always passes one. Its
  `BaseTool.run/1` should return
  `{:error, "<name> requires tool context; it was called outside the dispatch pipeline"}`
  so a caller that bypasses dispatch fails visibly.
  """

  @spec run(struct(), Normandy.Tools.Context.t()) :: {:ok, term()} | {:error, String.t()}
  def run(tool, ctx)
end
