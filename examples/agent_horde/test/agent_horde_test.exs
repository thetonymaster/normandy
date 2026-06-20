defmodule AgentHordeTest do
  use ExUnit.Case

  test "app module loads", do: assert(Code.ensure_loaded?(AgentHorde))

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
end
