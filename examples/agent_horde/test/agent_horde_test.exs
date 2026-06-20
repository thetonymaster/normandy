defmodule AgentHorde.Support.StubModel do
  @moduledoc "Stub LLM client for offline agent tests — returns stubbed prose."
  defstruct []

  defimpl Normandy.Agents.Model, for: __MODULE__ do
    def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
      response_model
    end

    def converse(_config, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
      {Map.put(response_model, :chat_message, "stubbed prose"), nil}
    end
  end
end

defmodule AgentHordeTest do
  use ExUnit.Case

  alias AgentHorde.Support.StubModel

  test "app module loads", do: assert(Code.ensure_loaded?(AgentHorde))

  describe "Agents.Planner" do
    test "config/0 has correct model and temperature" do
      cfg = AgentHorde.Agents.Planner.config()
      assert cfg.model == "claude-sonnet-4-6"
      assert cfg.temperature == 0.5
    end

    test "new/1 returns {:ok, agent} with stub client" do
      assert {:ok, _agent} = AgentHorde.Agents.Planner.new(client: %StubModel{})
    end

    test "run/2 returns stubbed prose via Text.of/1" do
      {:ok, agent} = AgentHorde.Agents.Planner.new(client: %StubModel{})
      {_agent2, response} = AgentHorde.Agents.Planner.run(agent, "test question")
      assert AgentHorde.Text.of(response) == "stubbed prose"
    end
  end

  describe "Agents.Curator" do
    test "config/0 has correct model and temperature" do
      cfg = AgentHorde.Agents.Curator.config()
      assert cfg.model == "claude-sonnet-4-6"
      assert cfg.temperature == 0.3
    end

    test "new/1 returns {:ok, agent} with stub client" do
      assert {:ok, _agent} = AgentHorde.Agents.Curator.new(client: %StubModel{})
    end

    test "run/2 returns stubbed prose via Text.of/1" do
      {:ok, agent} = AgentHorde.Agents.Curator.new(client: %StubModel{})
      {_agent2, response} = AgentHorde.Agents.Curator.run(agent, "test question")
      assert AgentHorde.Text.of(response) == "stubbed prose"
    end
  end

  describe "Agents.Analyst" do
    test "config/0 has correct baked model and temperature" do
      cfg = AgentHorde.Agents.Analyst.config()
      assert cfg.model == "claude-sonnet-4-6"
      assert cfg.temperature == 0.4
    end

    test "new/1 returns {:ok, agent} with stub client" do
      assert {:ok, _agent} = AgentHorde.Agents.Analyst.new(client: %StubModel{})
    end

    test "new/1 accepts model override at top level" do
      assert {:ok, agent} = AgentHorde.Agents.Analyst.new(client: %StubModel{}, model: "gpt-4o")
      assert agent.model == "gpt-4o"
    end

    test "run/2 returns stubbed prose via Text.of/1" do
      {:ok, agent} = AgentHorde.Agents.Analyst.new(client: %StubModel{})
      {_agent2, response} = AgentHorde.Agents.Analyst.run(agent, "test question")
      assert AgentHorde.Text.of(response) == "stubbed prose"
    end
  end

  describe "Agents.Editor" do
    test "config/0 has correct model, temperature, and max_tokens" do
      cfg = AgentHorde.Agents.Editor.config()
      assert cfg.model == "claude-sonnet-4-6"
      assert cfg.temperature == 0.4
      assert cfg.max_tokens == 4096
    end

    test "new/1 returns {:ok, agent} with stub client" do
      assert {:ok, _agent} = AgentHorde.Agents.Editor.new(client: %StubModel{})
    end

    test "run/2 returns stubbed prose via Text.of/1" do
      {:ok, agent} = AgentHorde.Agents.Editor.new(client: %StubModel{})
      {_agent2, response} = AgentHorde.Agents.Editor.run(agent, "test question")
      assert AgentHorde.Text.of(response) == "stubbed prose"
    end
  end

  describe "ExaSearch.parse/1" do
    test "normalizes results using text field" do
      body = %{
        "results" => [
          %{"url" => "https://a.com", "title" => "A", "text" => "snip A"}
        ]
      }

      assert AgentHorde.Tools.ExaSearch.parse(body) ==
               [%{url: "https://a.com", title: "A", snippet: "snip A"}]
    end

    test "falls back to snippet field when text is absent" do
      body = %{
        "results" => [
          %{"url" => "https://b.com", "title" => "B", "snippet" => "snip B"}
        ]
      }

      assert AgentHorde.Tools.ExaSearch.parse(body) ==
               [%{url: "https://b.com", title: "B", snippet: "snip B"}]
    end

    test "returns empty list for unexpected shape" do
      assert AgentHorde.Tools.ExaSearch.parse(%{}) == []
    end
  end

  describe "SerpAPISearch.parse/1" do
    test "normalizes organic_results" do
      body = %{
        "organic_results" => [
          %{"link" => "https://c.com", "title" => "C", "snippet" => "snip C"}
        ]
      }

      assert AgentHorde.Tools.SerpAPISearch.parse(body) ==
               [%{url: "https://c.com", title: "C", snippet: "snip C"}]
    end

    test "returns empty list for unexpected shape" do
      assert AgentHorde.Tools.SerpAPISearch.parse(%{}) == []
    end
  end

  describe "SerperSearch.parse/1" do
    test "normalizes organic" do
      body = %{
        "organic" => [
          %{"link" => "https://d.com", "title" => "D", "snippet" => "snip D"}
        ]
      }

      assert AgentHorde.Tools.SerperSearch.parse(body) ==
               [%{url: "https://d.com", title: "D", snippet: "snip D"}]
    end

    test "returns empty list for unexpected shape" do
      assert AgentHorde.Tools.SerperSearch.parse(%{}) == []
    end
  end

  describe "FirecrawlScrape.parse/2" do
    test "pulls markdown + title from nested body" do
      body = %{"data" => %{"markdown" => "# Hi", "metadata" => %{"title" => "Hi Page"}}}

      assert AgentHorde.Tools.FirecrawlScrape.parse("https://x.com", body) ==
               %{url: "https://x.com", title: "Hi Page", markdown: "# Hi"}
    end

    test "returns empty strings for missing keys" do
      assert AgentHorde.Tools.FirecrawlScrape.parse("https://x.com", %{}) ==
               %{url: "https://x.com", title: "", markdown: ""}
    end
  end

  @tag :live
  test "FirecrawlScrape live run returns markdown" do
    result =
      Normandy.Tools.BaseTool.run(%AgentHorde.Tools.FirecrawlScrape{
        url: "https://example.com"
      })

    assert {:ok, %{markdown: _}} = result
  end

  @tag :live
  test "ExaSearch live run returns results" do
    result =
      Normandy.Tools.BaseTool.run(%AgentHorde.Tools.ExaSearch{
        query: "elixir programming language"
      })

    assert {:ok, [_ | _]} = result
  end

  @tag :live
  test "SerpAPISearch live run returns results" do
    result =
      Normandy.Tools.BaseTool.run(%AgentHorde.Tools.SerpAPISearch{
        query: "elixir programming language"
      })

    assert {:ok, [_ | _]} = result
  end

  @tag :live
  test "SerperSearch live run returns results" do
    result =
      Normandy.Tools.BaseTool.run(%AgentHorde.Tools.SerperSearch{
        query: "elixir programming language"
      })

    assert {:ok, [_ | _]} = result
  end

  describe "AgentHorde.Clients" do
    test "openai/0 has correct base_url" do
      assert AgentHorde.Clients.openai().base_url == "https://api.openai.com/v1"
    end

    test "do_client/0 base_url comes from DO_INFERENCE_URL env var" do
      assert AgentHorde.Clients.do_client().base_url == System.get_env("DO_INFERENCE_URL")
    end

    test "providers/0 returns list of 3 tuples" do
      providers = AgentHorde.Clients.providers()
      assert length(providers) == 3

      Enum.each(providers, fn {label, client, model} ->
        assert is_binary(label)
        assert is_struct(client)
        assert is_binary(model)
      end)
    end

    test "providers/0 labels are Claude, GPT-4o, Llama (DO)" do
      labels = AgentHorde.Clients.providers() |> Enum.map(&elem(&1, 0))
      assert labels == ["Claude", "GPT-4o", "Llama (DO)"]
    end
  end

  describe "AgentHorde.Pipeline" do
    test "run/2 returns {:ok, %{path, report, stats}} with offline stubs" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("agent_horde_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      events = :ets.new(:test_events, [:ordered_set, :public])

      on_event = fn {stage, _payload} ->
        :ets.insert(events, {stage, true})
      end

      result =
        AgentHorde.Pipeline.run(
          "test question about elixir",
          search_tools: [%AgentHorde.Support.StubSearch{}],
          scrape_tool: %AgentHorde.Support.StubScrape{},
          claude_client: %AgentHorde.Support.StubModel{},
          providers: [{"Stub", %AgentHorde.Support.StubModel{}, "stub-model"}],
          reports_dir: tmp_dir,
          on_event: on_event
        )

      assert {:ok, %{path: path, report: report, stats: stats}} = result
      assert File.exists?(path)
      assert is_binary(report) and report != ""
      assert is_map(stats)

      # Verify on_event fired for each stage
      fired = :ets.tab2list(events) |> Enum.map(&elem(&1, 0))
      assert :plan in fired
      assert :search in fired
      assert :curate in fired
      assert :scrape in fired
      assert :analyze in fired
      assert :edit in fired
      assert :write in fired

      :ets.delete(events)
    end
  end

  describe "AgentHorde.Text.of/1" do
    test "binary passes through unchanged" do
      assert AgentHorde.Text.of("hi") == "hi"
    end

    test "map with :chat_message returns the message" do
      assert AgentHorde.Text.of(%{chat_message: "hi"}) == "hi"
    end

    test "map with :content list joins text blocks" do
      response = %{content: [%{text: "a"}, %{type: "text", text: "b"}]}
      assert AgentHorde.Text.of(response) == "a\nb"
    end

    test "unknown shape falls back to inspect" do
      value = %{other: "thing"}
      assert AgentHorde.Text.of(value) == inspect(value)
    end
  end

  describe "AgentHorde.CLI.format_event/1" do
    test ":plan event contains Planner and query count" do
      result = AgentHorde.CLI.format_event({:plan, %{queries: ["a", "b", "c"]}})
      assert result =~ "Planner"
      assert result =~ "3"
    end

    test ":search event contains search engine names and source count" do
      result = AgentHorde.CLI.format_event({:search, %{count: 12}})
      assert result =~ "Search"
      assert result =~ "12"
    end

    test ":curate event contains Curator and URL count" do
      result = AgentHorde.CLI.format_event({:curate, %{urls: ["https://a.com", "https://b.com"]}})
      assert result =~ "Curator"
      assert result =~ "2"
    end

    test ":scrape event contains Scraping and page count" do
      result = AgentHorde.CLI.format_event({:scrape, %{count: 4}})
      assert result =~ "Scrap"
      assert result =~ "4"
    end

    test ":analyze event contains provider names and count" do
      result = AgentHorde.CLI.format_event({:analyze, %{count: 3}})
      assert result =~ "Analyz"
      assert result =~ "3"
    end

    test ":edit event contains Editor" do
      result = AgentHorde.CLI.format_event({:edit, %{length: 2048}})
      assert result =~ "Editor"
    end

    test ":write event contains path and Wrote" do
      result = AgentHorde.CLI.format_event({:write, %{path: "/tmp/report.md"}})
      assert result =~ "Wrote"
      assert result =~ "/tmp/report.md"
    end
  end
end
