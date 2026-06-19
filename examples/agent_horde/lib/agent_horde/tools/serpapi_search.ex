defmodule AgentHorde.Tools.SerpAPISearch do
  @moduledoc """
  Search tool using SerpAPI (Google search results).

  Returns top organic results with URLs, titles, and snippets.
  Requires the SERPAPI_API_KEY environment variable.
  """

  defstruct [:query, results: nil]

  @doc """
  Parses a raw SerpAPI response body into a normalized list of result maps.

  Each result map has the keys: `:url`, `:title`, `:snippet`.
  """
  def parse(%{"organic_results" => results}) when is_list(results) do
    Enum.map(results, fn r ->
      %{
        url: r["link"],
        title: r["title"] || "",
        snippet: r["snippet"] || ""
      }
    end)
  end

  def parse(_), do: []

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "serpapi_search"

    def tool_description(_),
      do: "Google web search via SerpAPI. Returns top organic results with URLs and snippets."

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      }
    end

    def run(%{query: query}) do
      case Req.get("https://serpapi.com/search.json",
             params: [q: query, api_key: System.get_env("SERPAPI_API_KEY"), num: 5],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
          {:ok, @for.parse(body)}

        {:ok, %Req.Response{status: s, body: b}} ->
          {:error, "SerpAPI #{s}: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    end
  end
end
