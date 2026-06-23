defmodule AgentHorde.Tools.FirecrawlScrape do
  @moduledoc """
  Scrape tool using Firecrawl.

  Returns a page's markdown content and title.
  Requires the FIRECRAWL_API_KEY environment variable.
  """

  defstruct [:url]

  @doc """
  Parses a raw Firecrawl v2 scrape response body into a normalized map.

  Returns a map with keys: `:url`, `:title`, `:markdown`.
  Missing keys default to empty strings.
  """
  def parse(url, body) do
    data = body["data"] || %{}
    metadata = data["metadata"] || %{}

    %{
      url: url,
      title: metadata["title"] || "",
      markdown: data["markdown"] || ""
    }
  end

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "firecrawl_scrape"

    def tool_description(_),
      do: "Scrape a web page and return its content as markdown via Firecrawl."

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL of the page to scrape"}
        },
        required: ["url"]
      }
    end

    def run(%{url: url}) do
      case Req.post("https://api.firecrawl.dev/v2/scrape",
             json: %{url: url, formats: ["markdown"]},
             headers: [{"authorization", "Bearer " <> System.get_env("FIRECRAWL_API_KEY")}],
             receive_timeout: 60_000
           ) do
        {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
          {:ok, @for.parse(url, body)}

        {:ok, %Req.Response{status: s, body: b}} ->
          {:error, "Firecrawl #{s}: #{inspect(b)}"}

        {:error, e} ->
          {:error, inspect(e)}
      end
    end
  end
end
