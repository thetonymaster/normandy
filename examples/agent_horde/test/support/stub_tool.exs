defmodule AgentHorde.Support.StubSearch do
  @moduledoc "Offline stub for search tools — returns two fixed results."
  defstruct [:query]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "stub_search"
    def tool_description(_), do: "Offline stub search tool."
    def input_schema(_), do: %{type: "object", properties: %{}, required: []}

    def run(%{query: _query}) do
      {:ok,
       [
         %{url: "https://example.com/a", title: "Example A", snippet: "Snippet A"},
         %{url: "https://example.com/b", title: "Example B", snippet: "Snippet B"}
       ]}
    end
  end
end

defmodule AgentHorde.Support.StubScrape do
  @moduledoc "Offline stub for scrape tool — returns fixed markdown."
  defstruct [:url]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "stub_scrape"
    def tool_description(_), do: "Offline stub scrape tool."
    def input_schema(_), do: %{type: "object", properties: %{}, required: []}

    def run(%{url: url}) do
      {:ok,
       %{
         url: url,
         title: "Stub Page",
         markdown: "# Stub Content\n\nThis is stub markdown content for offline testing."
       }}
    end
  end
end
