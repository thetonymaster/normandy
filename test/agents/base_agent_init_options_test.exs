defmodule Normandy.Agents.BaseAgentInitOptionsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.InitOptions
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Test.StubClient

  @supported Enum.map_join(Keyword.keys(InitOptions.definition()), ", ", &inspect/1)

  defp client, do: %StubClient{}

  test "a keyword list works like a map" do
    from_keyword = BaseAgent.init(model: "m", client: client())
    from_map = BaseAgent.init(%{model: "m", client: client()})

    assert %BaseAgentConfig{model: "m", max_tokens: 16_000} = from_keyword
    assert from_keyword == from_map
  end

  test "the supported list starts with the required options" do
    assert String.starts_with?(@supported, ":client, :model, ")
  end

  test "an unknown option raises, naming it and the supported ones" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :temprature; supported: " <>
                   @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), temprature: 0.2) end
  end

  test ":system_prompt points at :prompt_specification" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :system_prompt; the system " <>
                   "prompt goes in :prompt_specification (a " <>
                   "%Normandy.Components.PromptSpecification{}); supported: " <> @supported,
                 fn ->
                   BaseAgent.init(model: "m", client: client(), system_prompt: "Be brief.")
                 end
  end

  test ":tools points at the tool registry" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :tools; tools go in " <>
                   ":toolset (Normandy.Tools.Toolset.new([tool, ...])) or are added " <>
                   "after init with BaseAgent.register_tool/3; supported: " <> @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), tools: []) end
  end

  test ":max_messages points at the memory" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :max_messages; cap the " <>
                   "memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages); " <>
                   "supported: " <> @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), max_messages: 10) end
  end

  test "a missing or nil :model raises, naming init/1" do
    for opts <- [[client: client()], [client: client(), model: nil], %{client: client()}] do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none",
                   fn -> BaseAgent.init(opts) end
    end
  end

  test "a missing :client is named" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: required :client option not found, " <>
                   "received options: [:model]",
                 fn -> BaseAgent.init(model: "m") end
  end

  test "a misspelled :model is named, not reported missing" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :modle; supported: " <>
                   @supported,
                 fn -> BaseAgent.init(client: client(), modle: "m") end
  end

  # Review Focus #5.
  test "a secret under a misspelled key is named, never shown" do
    error =
      assert_raise ArgumentError, fn ->
        BaseAgent.init(%{model: "m", client: client(), api_kye: "sk-ant-api03-canary"})
      end

    assert error.message =~ "unknown option :api_kye"
    refute error.message =~ "sk-"
  end

  test "a secret passed as the client is never shown" do
    error =
      assert_raise ArgumentError, fn ->
        BaseAgent.init(model: "m", client: "sk-ant-api03-canary")
      end

    assert error.message ==
             "Normandy.Agents.BaseAgent.init/1: invalid value for :client option: expected a " <>
               "struct implementing `Normandy.Agents.Model`; the value is not shown because " <>
               ":client can hold a secret"
  end

  test "a struct that does not implement Normandy.Agents.Model is rejected as the client" do
    error =
      assert_raise ArgumentError, fn -> BaseAgent.init(model: "m", client: %URI{}) end

    assert error.message =~ "Normandy.Agents.BaseAgent.init/1: invalid value for :client option"
  end

  test ":session_id is an option" do
    assert BaseAgent.init(model: "m", client: client(), session_id: "s-1").session_id == "s-1"
  end

  test "a list that is not a keyword list is rejected" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                   "map, got a list whose element 0 is an integer",
                 fn -> BaseAgent.init([1, 2]) end
  end

  test "every option is checked before anything starts" do
    {:links, before} = Process.info(self(), :links)

    assert_raise ArgumentError, ~r/:max_tool_iterations option/, fn ->
      BaseAgent.init(
        model: "m",
        client: client(),
        circuit_breaker: [],
        max_tool_iterations: 0
      )
    end

    assert Process.info(self(), :links) == {:links, before}
  end

  test "an unknown circuit breaker option is named" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: invalid value for :circuit_breaker option: " <>
                   "unknown option :error_threshold; supported: :failure_threshold, " <>
                   ":success_threshold, :timeout, :half_open_max_calls, :scope",
                 fn ->
                   BaseAgent.init(
                     model: "m",
                     client: client(),
                     circuit_breaker: [error_threshold: 3]
                   )
                 end
  end

  test "a duplicated circuit breaker option is reported as duplicated" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: invalid value for :circuit_breaker option: " <>
                   "option :timeout given more than once",
                 fn ->
                   BaseAgent.init(
                     model: "m",
                     client: client(),
                     circuit_breaker: [timeout: 1, timeout: 2]
                   )
                 end
  end

  test "init/1's docs list its options" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(BaseAgent)

    assert [%{"en" => doc}] =
             for({{:function, :init, 1}, _, _, doc, _} <- docs, do: doc)

    assert doc =~ "* `:model` (`t:String.t/0`) - Required."
    assert doc =~ "* `:session_id`"
    assert doc =~ "The default value is `16000`."
  end

  describe "a secret nested in a container value is never shown" do
    test "under a guardrail's opts" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: client(),
            guardrails: [input: [{Foo, %{api_key: "sk-LEAK"}}]]
          )
        end

      assert error.message =~ ":guardrails"
      refute error.message =~ "sk-"
    end

    test "under :retry's :retry_if" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(model: "m", client: client(), retry: [retry_if: %{api_key: "sk-LEAK"}])
        end

      assert error.message =~ ":retry_if"
      assert error.message =~ "got: a map"
      refute error.message =~ "sk-"
    end

    test "under a compactor's opts" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: client(),
            behaviours: %Normandy.Behaviours.Config{
              compactor: {Normandy.Behaviours.Compactor.WindowManager, %{api_key: "sk-LEAK"}}
            }
          )
        end

      assert error.message =~ "must be a keyword list, got a map"
      refute error.message =~ "sk-"
    end

    for {label, guardrails, bytes} <- [
          {"a string in a tuple", [input: [{Foo, "sk-LEAK"}]], 7},
          {"a bare string in a list", [input: ["sk-LEAK2"]], 8},
          {"a string in a builtin's opts",
           [output: [{Normandy.Guardrails.Builtins.MaxLength, "sk-LEAK3"}]], 8}
        ] do
      test "#{label} is described by type" do
        error =
          assert_raise ArgumentError, fn ->
            BaseAgent.init(
              client: client(),
              model: "m",
              guardrails: unquote(Macro.escape(guardrails))
            )
          end

        refute error.message =~ "sk-LEAK"
        assert error.message =~ "a string (#{unquote(bytes)} bytes)"
      end
    end

    test "a top-level scalar keeps NimbleOptions' message" do
      error = assert_raise ArgumentError, fn -> BaseAgent.init(client: client(), model: 123) end
      assert error.message =~ "123"
    end
  end
end
