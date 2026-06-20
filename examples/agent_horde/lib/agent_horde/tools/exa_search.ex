defmodule AgentHorde.Tools.ExaSearch do
  @moduledoc """
  Search tool using Exa neural search API.

  Returns top results with URLs, titles, and text snippets.
  Requires the EXA_API_KEY environment variable.
  """

  defstruct [:query, results: nil]

  @doc """
  Parses a raw Exa API response body into a normalized list of result maps.

  Each result map has the keys: `:url`, `:title`, `:snippet`.
  """
  def parse(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn r ->
      %{
        url: r["url"],
        title: r["title"] || "",
        snippet: r["text"] || r["snippet"] || ""
      }
    end)
  end

  def parse(_), do: []

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "exa_search"

    def tool_description(_),
      do: "Neural web search via Exa. Returns top results with URLs and snippets."

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
      case Req.post("https://api.exa.ai/search",
             json: %{query: query, numResults: 5, contents: %{text: true}},
             headers: [{"x-api-key", System.get_env("EXA_API_KEY")}],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
          {:ok, @for.parse(body)}

        {:ok, %Req.Response{status: s, body: b}} ->
          {:error, "Exa #{s}: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    end
  end
end
