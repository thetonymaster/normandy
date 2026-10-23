defmodule Normandy.Options.IntegrationOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.A2A.AgentTool
  alias Normandy.A2A.Registry, as: A2ARegistry
  alias Normandy.A2A.Server, as: A2AServer
  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate}
  alias Normandy.Behaviours.Compactor.WindowManager, as: WindowCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Context.{Summarizer, WindowManager}
  alias Normandy.Coordination.{AgentMessage, Pattern, StatefulContext}
  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Test.StubClient
  alias Normandy.Tools.Toolset

  @cases [
    {:skil_id, {AgentTool, :new, ["http://a", nil, [skil_id: "s"]]}},
    {:auth_tokn,
     {A2ARegistry, :discover_and_register, [%Toolset{}, "http://a", [auth_tokn: "t"]]}},
    {:auth_tokn, {A2ARegistry, :from_agent_card, [nil, "http://a", [auth_tokn: "t"]]}},
    {:expose_tool, {A2AServer, :build_agent_card, [%BaseAgentConfig{}, [expose_tool: :all]]}},
    {:prefx, {ToolWrapper, :new, [NoAdapter, nil, nil, [prefx: "p"]]}},
    {:prefx, {MCPRegistry, :discover_and_register, [%Toolset{}, NoAdapter, nil, [prefx: "p"]]}},
    {:prefx, {MCPRegistry, :wrap_tools, [NoAdapter, nil, [], [prefx: "p"]]}},
    {:prefx,
     {BaseAgent, :register_mcp_tools, [%BaseAgentConfig{}, NoAdapter, nil, [prefx: "p"]]}},
    {:max_token, {Summarizer, :summarize_messages, [nil, %{}, [], [max_token: 10]]}},
    {:max_summary_tokens,
     {Summarizer, :compress_conversation, [nil, %{}, [max_summary_tokens: 10]]}},
    {:summary_token, {Summarizer, :estimate_savings, [[], [summary_token: 2]]}},
    {:stratgy, {WindowManager, :new, [[max_tokens: 1000, stratgy: :oldest_first]]}},
    {:notify_on_chnage, {StatefulContext, :start_link, [[notify_on_chnage: false]]}},
    {:paylod, {AgentMessage, :new, [[paylod: %{}]]}},
    {:defualt, {Pattern, :ok_value, [{:ok, 1}, [defualt: 2]]}},
    {:defualt, {Pattern, :error_reason, [{:error, 1}, [defualt: 2]]}},
    {:turnid, {AgentMemory, :add_message, [%AgentMemory{}, "user", "hi", [turnid: "t"]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  describe "behaviour the schemas must keep" do
    test "a bad :auth_token value is not echoed in the error" do
      error =
        assert_raise ArgumentError, fn ->
          AgentTool.new("http://a", nil, auth_token: :"sk-ant-secret")
        end

      assert error.message =~ ":auth_token"
      refute error.message =~ "sk-ant-secret"
    end

    test "a bad :transport_opts value is not echoed in the error" do
      error =
        assert_raise ArgumentError, fn ->
          AgentTool.new("http://a", nil, transport_opts: "Bearer sk-ant-secret")
        end

      assert error.message =~ ":transport_opts"
      refute error.message =~ "sk-ant-secret"
    end

    test "AgentTool.new/3 keeps its registration-option message for :timeout" do
      error =
        assert_raise ArgumentError, fn -> AgentTool.new("http://a", nil, timeout: 1_000) end

      assert error.message =~ "Normandy.A2A.AgentTool.new/3: :timeout is a registration option"
    end

    test "A2A.Registry.from_agent_card/3 rejects :timeout (it used to drop it)" do
      assert_rejects(:timeout, A2ARegistry, :from_agent_card, [nil, "http://a", [timeout: 1]])
    end

    test "A2A.Registry.discover_and_register/3 takes :timeout as a positive integer" do
      error =
        assert_raise ArgumentError, fn ->
          A2ARegistry.discover_and_register(%Toolset{}, "http://a", timeout: 0)
        end

      assert error.message =~ "Normandy.A2A.Registry.discover_and_register/3: "
      assert error.message =~ ":timeout"
    end

    test "Pattern.ok_value/2 with valid options returns the value, or the default on {:error, _}" do
      assert Pattern.ok_value({:ok, 1}, default: 2) == 1
      assert Pattern.ok_value({:error, :x}, default: 2) == 2
    end

    test "compress_conversation/3 hands only the summary options to summarize_messages/4" do
      # Same setup as summarizer_test.exs "uses custom summary role when provided".
      client = %Normandy.Test.MockSummarizerClient{summary_response: "the summary"}

      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{
        memory: memory,
        model: "test-model",
        config: %{client: client, model: "test-model"}
      }

      assert {:ok, %{memory: compressed}} =
               Summarizer.compress_conversation(client, agent,
                 keep_recent: 5,
                 summary_role: "user",
                 max_tokens: 50
               )

      assert AgentMemory.count_messages(compressed) < AgentMemory.count_messages(memory)
    end

    test "a misspelled WindowManager compactor option raises when the agent is built" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: %StubClient{},
            behaviours: %Normandy.Behaviours.Config{
              compactor: {WindowCompactor, [context_window: 50_000, stratgy: :x]}
            }
          )
        end

      assert error.message =~ "Normandy.Agents.BaseAgent.init/1: "
      assert error.message =~ ":stratgy"
    end

    # Deferred from Task 3.2a: a :context_window that is not a positive integer used to
    # raise only mid-turn.
    for bad <- [nil, "200000", 0] do
      test "a WindowManager compactor :context_window of #{inspect(bad)} raises when the agent is built" do
        error =
          assert_raise ArgumentError, fn ->
            BaseAgent.init(
              model: "m",
              client: %StubClient{},
              behaviours: %Normandy.Behaviours.Config{
                compactor: {WindowCompactor, [context_window: unquote(bad)]}
              }
            )
          end

        assert error.message =~ "Normandy.Agents.BaseAgent.init/1: "
        assert error.message =~ ":context_window"
      end
    end

    test "a misspelled WindowManager compactor option raises when the template is rebuilt" do
      config = %BaseAgentConfig{
        model: "m",
        max_tokens: 100,
        prompt_specification: %Normandy.Components.PromptSpecification{},
        client: %StubClient{},
        toolset: Toolset.new(),
        behaviours: %Normandy.Behaviours.Config{
          compactor: {WindowCompactor, [context_window: 50_000, stratgy: :x]}
        }
      }

      tmpl = ConfigTemplate.from_config(config, "t")

      supplement = %{
        toolset: Toolset.new(),
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> %StubClient{} end
      }

      error =
        assert_raise ArgumentError, fn -> ConfigTemplate.rebuild(tmpl, supplement, "TOKEN") end

      assert error.message =~ "Normandy.Agents.ConfigTemplate.rebuild/3: "
      assert error.message =~ ":stratgy"
    end

    test "AgentTool.new/3 and WindowManager.new/1 take their options as a map too" do
      assert %AgentTool{skill_id: "s"} =
               AgentTool.new("http://a", nil, %{prefix: "a2a", skill_id: "s"})

      assert %WindowManager{max_tokens: 1000} = WindowManager.new(%{max_tokens: 1000})

      assert_raise ArgumentError,
                   ~r/^Normandy\.A2A\.AgentTool\.new\/3: :timeout is a registration/,
                   fn ->
                     AgentTool.new("http://a", nil, %{timeout: 1})
                   end
    end

    test "WindowManager.new/1 keeps its explanation for a missing :max_tokens" do
      error = assert_raise ArgumentError, fn -> WindowManager.new(strategy: :oldest_first) end

      assert error.message =~
               ~r/^Normandy\.Context\.WindowManager\.new\/1: requires :max_tokens/
    end
  end
end
