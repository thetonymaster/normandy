defmodule AgentHorde.Tools.SerperSearch do
  @moduledoc """
  Search tool using Serper (Google search results).

  Returns top organic results with URLs, titles, and snippets.
  Requires the SERPER_API_KEY environment variable.
  """

  defstruct [:query, results: nil]

  @doc """
  Parses a raw Serper API response body into a normalized list of result maps.

  Each result map has the keys: `:url`, `:title`, `:snippet`.
  """
  def parse(%{"organic" => results}) when is_list(results) do
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
    def tool_name(_), do: "serper_search"

    def tool_description(_),
      do: "Google web search via Serper. Returns top organic results with URLs and snippets."

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
      case Req.post("https://google.serper.dev/search",
             json: %{q: query, num: 5},
             headers: [{"x-api-key", System.get_env("SERPER_API_KEY")}],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
          {:ok, @for.parse(body)}

        {:ok, %Req.Response{status: s, body: b}} ->
          {:error, "Serper #{s}: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    end
  end
end
