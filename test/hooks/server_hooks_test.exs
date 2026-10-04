defmodule Normandy.Hooks.ServerHooksTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}

  # The FSM finalizes on a response with no tool_calls. Normandy.Test.TurnConfig.Resp has
  # no BaseIOSchema impl; this one does, so AgentMemory.history/1 can render memory.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def __str__(resp), do: resp.content
    def __rich__(resp), do: resp.content
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Built directly, as a :config start takes it (Turn.Server saves no template for a
  # :config start, server.ex:265-270): BaseAgent.init/1 validation does not run, so the
  # server's own load-time check is what these tests see.
  defp config(hooks, extra) do
    Map.merge(
      %BaseAgentConfig{
        input_schema: nil,
        output_schema: %Resp{},
        client: nil,
        model: "test",
        name: "server-hooks",
        memory: AgentMemory.new_memory(),
        initial_memory: AgentMemory.new_memory(),
        prompt_specification: %PromptSpecification{},
        tool_registry: nil,
        behaviours: %Config{hooks: hooks}
      },
      extra
    )
  end

  defp llm(content \\ "hi"),
    do: fn _config, _state, _request -> %Resp{content: content, tool_calls: nil} end

  # opts: :config (map merged into config/2), :handlers (map merged into the stubbed
  # default set), :store ({mod, handle}); the rest go to Turn.Server.start_link/1.
  defp start(sid, hooks, opts \\ []) do
    {config_extra, opts} = Keyword.pop(opts, :config, %{})
    {handler_overrides, opts} = Keyword.pop(opts, :handlers, %{})
    {store, opts} = Keyword.pop_lazy(opts, :store, fn -> {InMemory, InMemory.new()} end)

    handlers =
      Map.merge(%{BaseAgent.non_streaming_handlers() | call_llm: llm()}, handler_overrides)

    Turn.Server.start_link(
      [
        session_id: sid,
        config: config(hooks, config_extra),
        store: store,
        registry: {Native, Native.new()},
        handlers: handlers
      ] ++ opts
    )
  end

  defp sid, do: "server-hooks-#{System.unique_integer([:positive])}"

  describe "hook entries checked at load" do
    test "a hook module missing on this node keeps the server :unavailable with the reason" do
      {:ok, srv} = start(sid(), [{Gone.Hook, []}])

      assert {:unavailable, _} = :sys.get_state(srv)

      assert Turn.Server.run(srv, "hello") ==
               {:error, {:invalid_hooks, "hook module Gone.Hook is not available"}}

      assert Process.alive?(srv)
    end
  end
end
