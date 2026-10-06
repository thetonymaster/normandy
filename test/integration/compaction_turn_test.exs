defmodule Normandy.Integration.CompactionTurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory

  defp big_memory do
    Enum.reduce(1..60, AgentMemory.new_memory(nil), fn i, m ->
      AgentMemory.add_message(m, "user", "padded conversation message number #{i} text")
    end)
  end

  test "default (NoOp) compactor leaves memory untouched at the steering boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{}
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == AgentMemory.history(config.memory)
  end

  test "opt-in WindowManager compactor with a tiny window truncates at the boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{
        compactor: {Compactor.WindowManager, [context_window: 80, reserved_tokens: 16]}
      }
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert meta.compacted == true
    assert meta.tokens_after < meta.tokens_before

    assert length(AgentMemory.history(config2.memory)) <
             length(AgentMemory.history(config.memory))
  end

  defmodule StubCatalog do
    @behaviour Normandy.Behaviours.ModelCatalog

    @impl true
    def context_window(model, opts) do
      send(Keyword.fetch!(opts, :notify), {:catalog_lookup, model, Keyword.get(opts, :client)})
      Keyword.fetch!(opts, :reply)
    end
  end

  defp catalog_config(model, reply, client \\ nil) do
    %BaseAgentConfig{
      model: model,
      client: client,
      memory: big_memory(),
      behaviours: %Config{
        compactor: {Compactor.WindowManager, [reserved_tokens: 16]},
        model_catalog: {StubCatalog, [notify: self(), reply: reply]}
      }
    }
  end

  test "a pinned :context_window never consults the catalog" do
    config = %BaseAgentConfig{
      model: "claude-opus-5-5",
      memory: big_memory(),
      behaviours: %Config{
        compactor: {Compactor.WindowManager, [context_window: 80, reserved_tokens: 16]},
        model_catalog: {StubCatalog, [notify: self(), reply: {:error, :must_not_be_called}]}
      }
    }

    {_config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert meta.compacted == true
    refute_received {:catalog_lookup, _, _}
  end

  test "the NoOp compactor never consults the catalog" do
    config = %{
      catalog_config("m", {:error, :must_not_be_called})
      | behaviours: %Config{model_catalog: {StubCatalog, [notify: self(), reply: {:error, :x}]}}
    }

    {_config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert meta.compacted == false
    refute_received {:catalog_lookup, _, _}
  end

  test "the window is looked up once per model and memoised on the config" do
    config = catalog_config("claude-opus-5-5", {:ok, 80})

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert meta.compacted == true
    assert config2.resolved_context_window == {"claude-opus-5-5", 80}
    assert_received {:catalog_lookup, "claude-opus-5-5", nil}

    {_config3, _} =
      BaseAgent.compact_turn_memory(config2, %Turn.State{}, %{
        iterations_left: 2,
        mid_round: false
      })

    refute_received {:catalog_lookup, _, _}
  end

  test "a model change triggers a fresh lookup" do
    config = %{
      catalog_config("claude-opus-5-5", {:ok, 80})
      | resolved_context_window: {"claude-sonnet-5-5", 80}
    }

    {_config2, _} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert_received {:catalog_lookup, "claude-opus-5-5", nil}
  end

  test "a config built under 1.x (no :resolved_context_window key) memoises without KeyError" do
    config = Map.delete(catalog_config("claude-opus-5-5", {:ok, 80}), :resolved_context_window)

    {config2, _} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})

    assert config2.resolved_context_window == {"claude-opus-5-5", 80}
  end

  test "a catalog returning a non-positive-integer window raises ModelCatalogError" do
    config = catalog_config("claude-opus-5-5", {:ok, nil})

    assert_raise Normandy.ModelCatalogError,
                 ~r/claude-opus-5-5.*\{:invalid_context_window, nil\}/s,
                 fn ->
                   BaseAgent.compact_turn_memory(config, %Turn.State{}, %{
                     iterations_left: 3,
                     mid_round: false
                   })
                 end
  end

  test "a catalog lookup error raises ModelCatalogError naming the model and reason" do
    config = catalog_config("claude-opus-5-5", {:error, :boom})

    assert_raise Normandy.ModelCatalogError, ~r/claude-opus-5-5.*:boom/s, fn ->
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})
    end
  end

  test "a Claudio client is handed to the catalog as a Req client honouring base_url" do
    client = %Normandy.LLM.ClaudioAdapter{api_key: "k", base_url: "http://localhost:4010/"}

    {_config2, _} =
      BaseAgent.compact_turn_memory(catalog_config("m", {:ok, 80}, client), %Turn.State{}, %{
        iterations_left: 3,
        mid_round: false
      })

    assert_received {:catalog_lookup, "m", %Req.Request{} = req}
    assert to_string(Req.Request.get_option(req, :base_url)) =~ "localhost:4010"
  end

  test "a non-Claudio client with an unpinned compactor gets a clear error from the default catalog" do
    config = %BaseAgentConfig{
      model: "gpt-x",
      client: nil,
      memory: big_memory(),
      behaviours: %Config{compactor: {Compactor.WindowManager, [reserved_tokens: 16]}}
    }

    assert_raise Normandy.ModelCatalogError, ~r/:no_client.*:context_window/s, fn ->
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3, mid_round: false})
    end
  end
end
