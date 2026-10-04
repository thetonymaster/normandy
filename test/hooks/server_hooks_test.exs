defmodule Normandy.Hooks.ServerHooksTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate, Turn}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

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

  defmodule QueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
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

  defp probe(opts), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}

  describe "hook entries checked at load" do
    test "a hook module missing on this node keeps the server :unavailable with the reason" do
      {:ok, srv} = start(sid(), [{Gone.Hook, []}])

      assert {:unavailable, _} = :sys.get_state(srv)

      assert Turn.Server.run(srv, "hello") ==
               {:error, {:invalid_hooks, "hook module Gone.Hook is not available"}}

      assert Process.alive?(srv)
    end
  end

  describe "on_prompt" do
    test "a halt replies {:rejected, %HookHaltError{}}, stores nothing and keeps the server" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} =
        start(session, [probe(returns: [on_prompt: {:halt, "off-topic"}])],
          store: {InMemory, store}
        )

      assert {:error,
              {:rejected,
               %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"}}} =
               Turn.Server.run(srv, "hello")

      assert {:ok, []} = InMemory.history(store, session)
      assert Process.alive?(srv)
    end

    test "the hook sees the validated input; the rewrite is what the store holds" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_prompt: {:cont, %QueryInput{query: "[redacted]"}}])]

      {:ok, srv} =
        start(session, hooks, store: {InMemory, store}, config: %{input_schema: %QueryInput{}})

      assert {:ok, _} = Turn.Server.run(srv, %{"query" => "my ssn is 1"})

      assert_receive {:hook, :p, :on_prompt,
                      [%QueryInput{query: "my ssn is 1"}, %Normandy.Hooks.Context{turn_id: nil}]}

      assert {:ok, [%{role: "user", content: %QueryInput{query: "[redacted]"}} | _]} =
               InMemory.history(store, session)
    end

    test "a hook crashing under :reraise replies {:handler_crashed, :admit, e}; the server lives" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:raise, "redactor down"}])])

      assert {:error, {:handler_crashed, :admit, %RuntimeError{message: "redactor down"}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
      assert {:error, {:handler_crashed, :admit, _}} = Turn.Server.run(srv, "again")
    end

    test "a contract violation is replied the same way" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: :yes])])

      assert {:error, {:handler_crashed, :admit, %ArgumentError{}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "hooks saved in a config template run after a thin start" do
      sink = TestHooks.sink()
      session = sid()
      store = InMemory.new()
      {:ok, catalog} = Catalog.start_link([])

      :ok =
        Catalog.put(catalog, "hooks-kind", %{
          tool_registry: nil,
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> nil end
        })

      behaviours = %Config{
        hooks: [{Probe, notify: sink, tag: :tmpl}],
        credential: {Normandy.Test.StubCreds, []}
      }

      tmpl = ConfigTemplate.from_config(config([], %{behaviours: behaviours}), "hooks-kind")
      :ok = InMemory.save_config_template(store, session, tmpl)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: session,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          template_provider: {Catalog, catalog},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: llm()}
        )

      assert {:ok, %Resp{content: "hi"}} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :tmpl, :on_prompt, ["hello", _ctx]}
    end
  end
end
