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
end
