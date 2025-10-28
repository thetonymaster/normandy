defmodule CustomerSupport.Tools.KnowledgeBaseTool do
  @moduledoc """
  Tool for searching the knowledge base for answers to common questions.

  Searches through FAQs, documentation, and troubleshooting guides to find
  relevant information for customer queries.
  """

  defstruct [:query, :category]

  defimpl Normandy.Tools.BaseTool do
    alias CustomerSupport.DataStore.KnowledgeBase

    def tool_name(_), do: "knowledge_base_search"

    def tool_description(_) do
      """
      Search the knowledge base for information about products, policies,
      troubleshooting, and common questions. Optionally filter by category.
      """
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query or question to look up"
          },
          category: %{
            type: "string",
            description: "Optional category to filter results",
            enum: ["shipping", "returns", "technical", "billing", "general"]
          }
        },
        required: ["query"]
      }
    end

    def run(%{query: query} = params) do
      category = Map.get(params, :category)

      case KnowledgeBase.search(query, category) do
        {:ok, []} ->
          {:error, "No information found for query: #{query}"}

        {:ok, results} ->
          {:ok, format_results(results)}

        {:error, reason} ->
          {:error, "Knowledge base search failed: #{inspect(reason)}"}
      end
    end

    defp format_results(results) do
      results
      |> Enum.take(3)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {result, index} ->
        """
        #{index}. #{result.title} [#{result.category}]
        #{result.content}
        """
      end)
    end
  end
end
