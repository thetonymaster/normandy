defmodule AgentHorde.Pipeline do
  @moduledoc """
  7-stage research orchestration pipeline.

  Decomposes a question into queries, fans out searches in parallel,
  curates URLs, scrapes pages in parallel, runs analyst fan-out across
  LLM providers, synthesizes with an editor, and writes the report to disk.

  ## Options (all support offline/test dependency injection)

  - `:search_tools` — list of `BaseTool` structs (default: ExaSearch, SerpAPISearch, SerperSearch)
  - `:scrape_tool` — a `BaseTool` struct (default: FirecrawlScrape)
  - `:claude_client` — a `Model` client used for Planner, Curator, Editor (default: `Clients.claude/0`)
  - `:providers` — list of `{label, client, model}` triples for analysts (default: `Clients.providers/0`)
  - `:reports_dir` — directory to write the report (default: `priv/reports`)
  - `:on_event` — `fn {stage_atom, payload} -> :ok end` called at each stage boundary

  ## Return value

      {:ok, %{path: String.t(), report: String.t(), stats: map()}}
  """

  alias AgentHorde.Agents.{Planner, Curator, Analyst, Editor}
  alias AgentHorde.{Clients, Text}
  alias AgentHorde.Tools.{ExaSearch, SerpAPISearch, SerperSearch, FirecrawlScrape}

  @url_regex ~r{https?://\S+}

  @doc """
  Run the 7-stage research pipeline for `question`.

  Returns `{:ok, %{path: path, report: report, stats: stats}}`.
  """
  def run(question, opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    on_event = opts[:on_event] || fn _event -> :ok end

    claude = opts[:claude_client] || Clients.claude()
    providers = opts[:providers] || Clients.providers()
    reports_dir = opts[:reports_dir] || default_reports_dir()

    search_tools =
      opts[:search_tools] ||
        [%ExaSearch{}, %SerpAPISearch{}, %SerperSearch{}]

    scrape_tool = opts[:scrape_tool] || %FirecrawlScrape{}

    # Stage 1: Planner
    queries = plan(question, claude, on_event)

    # Stage 2: Search fan-out
    merged = search(queries, search_tools, on_event)

    # Stage 3: Curator picks URLs
    urls = curate(question, merged, claude, on_event)

    # Stage 4: Scrape chosen URLs
    scraped = scrape(urls, scrape_tool, on_event)

    # Stage 5: Analyst fan-out across providers
    analyses = analyze(question, scraped, providers, on_event)

    # Stage 6: Editor synthesizes
    report = edit(question, analyses, scraped, claude, on_event)

    # Stage 7: Write report to disk
    path = write(question, report, reports_dir, on_event)

    t1 = System.monotonic_time(:millisecond)

    stats = %{
      queries: length(queries),
      search_results: length(merged),
      urls_scraped: length(scraped),
      analyses: length(analyses),
      elapsed_ms: t1 - t0
    }

    {:ok, %{path: path, report: report, stats: stats}}
  end

  # ---------------------------------------------------------------------------
  # Stage functions
  # ---------------------------------------------------------------------------

  @doc false
  def plan(question, claude, on_event) do
    {:ok, agent} = Planner.new(client: claude)
    {_agent, response} = Planner.run(agent, question)
    queries = Text.of(response) |> String.split("\n", trim: true) |> Enum.take(3)
    on_event.({:plan, %{queries: queries}})
    queries
  end

  @doc false
  def search(queries, tools, on_event) do
    first_query = List.first(queries, "")

    results =
      tools
      |> Task.async_stream(
        fn tool ->
          t = Map.put(tool, :query, first_query)
          Normandy.Tools.BaseTool.run(t)
        end,
        max_concurrency: 3,
        timeout: 40_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, list}} when is_list(list) -> list
        _ -> []
      end)

    merged = Enum.uniq_by(results, & &1.url)
    on_event.({:search, %{count: length(merged)}})
    merged
  end

  @doc false
  def curate(question, merged, claude, on_event) do
    numbered =
      merged
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> "#{i}. #{r.url} — #{r.title}: #{r.snippet}" end)
      |> Enum.join("\n")

    prompt = "Question: #{question}\n\nSearch results:\n#{numbered}"

    {:ok, agent} = Curator.new(client: claude)
    {_agent, response} = Curator.run(agent, prompt)

    urls =
      Text.of(response)
      |> extract_urls()
      |> Enum.take(4)

    urls =
      if Enum.empty?(urls) do
        merged |> Enum.take(4) |> Enum.map(& &1.url)
      else
        urls
      end

    on_event.({:curate, %{urls: urls}})
    urls
  end

  @doc false
  def scrape(urls, scrape_tool, on_event) do
    scraped =
      urls
      |> Task.async_stream(
        fn url ->
          t = Map.put(scrape_tool, :url, url)
          Normandy.Tools.BaseTool.run(t)
        end,
        max_concurrency: 4,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, page}} ->
          [%{page | markdown: String.slice(page.markdown, 0, 6000)}]

        _ ->
          []
      end)

    on_event.({:scrape, %{count: length(scraped)}})
    scraped
  end

  @doc false
  def analyze(question, scraped, providers, on_event) do
    corpus = format_corpus(scraped)

    analyses =
      providers
      |> Task.async_stream(
        fn {label, client, model} ->
          {:ok, agent} = Analyst.new(client: client, model: model)
          prompt = "Question: #{question}\n\nSources:\n#{corpus}"
          {_agent, response} = Analyst.run(agent, prompt)
          {label, Text.of(response)}
        end,
        max_concurrency: 3,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, pair} -> [pair]
        _ -> []
      end)

    on_event.({:analyze, %{count: length(analyses)}})
    analyses
  end

  @doc false
  def edit(question, analyses, scraped, claude, on_event) do
    prompt = editor_prompt(question, analyses, scraped)
    {:ok, agent} = Editor.new(client: claude)
    {_agent, response} = Editor.run(agent, prompt)
    report = Text.of(response)
    on_event.({:edit, %{length: byte_size(report)}})
    report
  end

  @doc false
  def write(question, report, reports_dir, on_event) do
    File.mkdir_p!(reports_dir)
    path = Path.join(reports_dir, slug(question) <> "-" <> timestamp() <> ".md")
    File.write!(path, report)
    on_event.({:write, %{path: path}})
    path
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp extract_urls(text) do
    Regex.scan(@url_regex, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp format_corpus(scraped) do
    scraped
    |> Enum.with_index(1)
    |> Enum.map(fn {page, i} ->
      """
      ## Source #{i}: #{page.title}
      URL: #{page.url}

      #{page.markdown}
      """
    end)
    |> Enum.join("\n---\n")
  end

  defp editor_prompt(question, analyses, scraped) do
    analyses_text =
      analyses
      |> Enum.map(fn {label, prose} -> "### #{label}\n#{prose}" end)
      |> Enum.join("\n\n")

    sources =
      scraped
      |> Enum.map(& &1.url)
      |> Enum.join("\n- ")

    """
    Question: #{question}

    ## Analyst Findings

    #{analyses_text}

    ## Sources Scraped

    - #{sources}

    Synthesize the above findings into a single well-structured Markdown report.
    """
  end

  defp slug(question) do
    question
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[T:Z\-]/, "")
    |> String.slice(0, 15)
  end

  defp default_reports_dir do
    Path.join(Application.app_dir(:agent_horde), "priv/reports")
  end
end
