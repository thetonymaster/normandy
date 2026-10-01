defmodule Normandy.Agents.BaseAgentCompactionConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.{Compactor, Config}

  defmodule OtherClient do
    defstruct api_key: "sk-secret-do-not-print"
  end

  defmodule CustomCatalog do
    @behaviour Normandy.Behaviours.ModelCatalog
    @impl true
    def context_window(_model, _opts), do: {:ok, 100_000}
  end

  defp init(client, behaviours) do
    BaseAgent.init(%{client: client, model: "m", temperature: nil, behaviours: behaviours})
  end

  @pinned %Config{compactor: {Compactor.WindowManager, [max_tokens: 50_000]}}
  @unpinned %Config{compactor: {Compactor.WindowManager, [reserved_tokens: 16]}}

  test "a non-Claudio client with an unpinned compactor and the default catalog raises at init" do
    error = assert_raise ArgumentError, fn -> init(%OtherClient{}, @unpinned) end

    assert error.message =~ "Compactor.WindowManager"
    assert error.message =~ ":max_tokens"
    assert error.message =~ "OtherClient"
    refute error.message =~ "sk-secret"
  end

  test "compactor opts that are not a keyword list raise a named ArgumentError" do
    behaviours = %Config{compactor: {Compactor.WindowManager, %{}}}
    error = assert_raise ArgumentError, fn -> init(%OtherClient{}, behaviours) end

    assert error.message =~ "BaseAgent.validate_compaction_config!/1"
    assert error.message =~ "Compactor.WindowManager"
    assert error.message =~ "keyword list"
    refute error.message =~ "sk-secret"
  end

  test "the deprecated Static catalog is treated like the default" do
    # Built at runtime: a compiled Static literal under test/ would make the 1.x
    # [:safe] decode test in config_template_test vacuous (one shared VM).
    static = Module.safe_concat([Normandy.Behaviours.ModelCatalog, "Static"])
    behaviours = %{@unpinned | model_catalog: {static, []}}
    assert_raise ArgumentError, fn -> init(%OtherClient{}, behaviours) end
  end

  test "passes when :max_tokens is pinned" do
    pinned = %Config{compactor: {Compactor.WindowManager, [max_tokens: 50_000]}}
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, pinned)
  end

  test "passes with the NoOp compactor (the default)" do
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, nil)
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, %Config{})
  end

  test "passes with a Claudio client" do
    client = %Normandy.LLM.ClaudioAdapter{api_key: "k"}
    assert %Normandy.Agents.BaseAgentConfig{} = init(client, @unpinned)
  end

  test "passes with a custom catalog (it may work with any client)" do
    behaviours = %{@unpinned | model_catalog: {CustomCatalog, []}}
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, behaviours)
  end

  describe "ClaudioAdapter client options" do
    alias Normandy.LLM.ClaudioAdapter

    test "init raises at configuration time for an invalid options combination" do
      client = %ClaudioAdapter{
        api_key: "sk-secret",
        options: %{thinking: :adaptive, thinking_budget: 1024}
      }

      error = assert_raise ArgumentError, fn -> init(client, nil) end
      assert error.message =~ "mutually exclusive"
      refute error.message =~ "sk-secret"
    end

    test "init accepts valid ClaudioAdapter options and ignores non-Claudio clients" do
      assert %{} = init(%ClaudioAdapter{api_key: "k", options: %{effort: :high}}, @pinned)
      assert %{} = init(%OtherClient{}, nil)
    end
  end
end
