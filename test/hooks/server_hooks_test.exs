defmodule Normandy.Hooks.ServerHooksTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate, Turn}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}
  alias Normandy.Hooks.ServerGlue
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe
  alias Normandy.Test.KeepLastCompactor

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

  # Holds on_turn_end until released: run/2 returning while it waits proves the reply
  # went out first.
  defmodule HoldsTurnEnd do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_turn_end(_outcome, _ctx, opts) do
      send(opts[:notify], :turn_end_running)

      receive do
        :release -> :ok
      end
    end
  end

  # Fails every "user" append; everything else goes to InMemory.
  defmodule UserAppendFailStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory
    def new, do: InMemory.new()
    def append_entry(_h, _sid, %{role: "user"}), do: {:error, :disk_full}
    def append_entry(h, sid, e), do: InMemory.append_entry(h, sid, e)
    def save_turn_state(h, sid, t), do: InMemory.save_turn_state(h, sid, t)
    def load_turn_state(h, sid), do: InMemory.load_turn_state(h, sid)
    def history(h, sid), do: InMemory.history(h, sid)
  end

  # Holds on_session_start until released: start_link returning while it waits proves
  # the hook runs after init/1.
  defmodule HoldsSessionStart do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_session_start(_ctx, opts) do
      send(opts[:notify], :session_start_running)

      receive do
        :release -> :ok
      end
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

  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}

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

  describe "on_turn_end" do
    test "a completed turn reports {:ok, final} with the turn's id" do
      {:ok, srv} = start(sid(), [probe()])

      assert {:ok, %Resp{content: "hi"} = final} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :on_turn_end, [{:ok, ^final}, ctx]}
      refute is_nil(ctx.turn_id)
    end

    test "the caller gets the reply before on_turn_end runs" do
      {:ok, srv} = start(sid(), [{HoldsTurnEnd, notify: TestHooks.sink()}])

      task = Task.async(fn -> Turn.Server.run(srv, "hello") end)
      assert {:ok, {:ok, %Resp{content: "hi"}}} = Task.yield(task, 2_000)
      assert_receive :turn_end_running
      send(srv, :release)
    end

    test "a crashing or contract-violating on_turn_end changes neither the reply nor the server" do
      {:ok, crashing} = start(sid(), [probe(returns: [on_turn_end: {:raise, "audit down"}])])
      assert {:ok, _} = Turn.Server.run(crashing, "hello")

      {:ok, violating} = start(sid(), [probe(returns: [on_turn_end: :done])])
      assert {:ok, _} = Turn.Server.run(violating, "hello")

      assert Process.alive?(crashing)
      assert Process.alive?(violating)
    end

    test "a rejected input reports {:rejected, e} with no turn id" do
      {:ok, srv} = start(sid(), [probe()], config: %{input_schema: %QueryInput{}})

      assert {:error, {:rejected, %Normandy.Schema.ValidationError{}}} =
               Turn.Server.run(srv, %{})

      assert_receive {:hook, :p, :on_turn_end,
                      [
                        {:rejected, %Normandy.Schema.ValidationError{}},
                        %Normandy.Hooks.Context{turn_id: nil}
                      ]}
    end

    test "an admission crash reports {:error, {:handler_crashed, :admit, e}}" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:raise, "x"}])])

      assert {:error, {:handler_crashed, :admit, _}} = Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end,
                      [{:error, {:handler_crashed, :admit, %RuntimeError{}}}, _ctx]}
    end

    test "a failed write of the turn's first message reports {:error, {:persist_failed, reason}}" do
      {:ok, srv} =
        start(sid(), [probe()], store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :on_turn_end, [{:error, {:persist_failed, :disk_full}}, _ctx]}
    end

    test "ServerGlue.fail_outcome/1: an output-guardrail block is a rejection, the rest errors" do
      e = %Normandy.Guardrails.ViolationError{message: "blocked", violations: []}
      assert ServerGlue.fail_outcome({:rejected, e}) == {:rejected, e}

      assert ServerGlue.fail_outcome({:approval_timeout, ["t"]}) ==
               {:error, {:approval_timeout, ["t"]}}
    end
  end

  describe "before_llm and after_compact with the server's handlers" do
    # start/3 always passes custom handlers (a stubbed call_llm): these tests prove the
    # hooks do not depend on BaseAgent's own handler functions.
    test "before_llm runs once per LLM call" do
      {:ok, srv} = start(sid(), [probe()])

      assert {:ok, _} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :before_llm, [%{final: false}, _ctx]}
      refute_received {:hook, :p, :before_llm, _}
    end

    test "a before_llm halt replies {:hook_halted, e} and on_turn_end sees the same" do
      {:ok, srv} = start(sid(), [probe(returns: [before_llm: {:halt, "budget"}])])

      assert {:error,
              {:hook_halted,
               %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget"} = e}} =
               Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end, [{:error, {:hook_halted, ^e}}, _ctx]}
      assert Process.alive?(srv)
    end

    test "after_compact gets dropped entries under their store ids; injections stay out of the store" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [after_compact: {:inject, ["remember: metric"]}])]

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, max_tokens: 200_000}
      }

      {:ok, srv} =
        start(session, hooks, store: {InMemory, store}, config: %{behaviours: behaviours})

      assert {:ok, _} = Turn.Server.run(srv, "one")
      {:ok, first_turn} = InMemory.history(store, session)

      assert {:ok, _} = Turn.Server.run(srv, "two")
      assert_receive {:hook, :p, :after_compact, [dropped, _meta, _ctx]}
      assert Enum.map(dropped, & &1.id) == Enum.map(first_turn, & &1.id)

      {:ok, stored} = InMemory.history(store, session)
      refute Enum.any?(stored, &(&1.content == "remember: metric"))

      {_state, data} = :sys.get_state(srv)

      assert Enum.any?(
               AgentMemory.messages(data.config.memory),
               &(&1.content == "remember: metric")
             )
    end
  end

  describe "on_session_start" do
    test "a new session runs it after init; its texts are stored as one user message" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric", "plan: pro"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})

      assert_receive {:hook, :p, :on_session_start, [ctx]}
      assert %Normandy.Hooks.Context{session_id: ^session, turn_id: nil} = ctx

      {_state, data} = :sys.get_state(srv)

      assert {:ok, [%{role: "user", content: "profile: metric\n\nplan: pro"}]} =
               InMemory.history(store, session)

      assert ["profile: metric\n\nplan: pro"] =
               data.config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)
    end

    test "start_link returns before the hook runs" do
      sink = TestHooks.sink()
      test = self()

      # The server is linked to its starter and stops with it, so the starter stays alive.
      starter =
        spawn_link(fn ->
          send(test, {:started, start(sid(), [{HoldsSessionStart, notify: sink}])})

          receive do
            :done -> :ok
          end
        end)

      assert_receive {:started, {:ok, srv}}, 2_000
      assert_receive :session_start_running
      send(srv, :release)
      assert {:idle, _} = :sys.get_state(srv)
      send(starter, :done)
    end

    test "a restarted session that stored its injection does not run it again" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
      :ok = :gen_statem.stop(srv)

      {:ok, srv2} = start(session, hooks, store: {InMemory, store})
      {_state, data} = :sys.get_state(srv2)

      refute_received {:hook, :p, :on_session_start, _}

      assert ["profile: metric"] =
               data.config.memory |> AgentMemory.messages() |> Enum.map(& &1.content)
    end

    test "a session whose hooks injected nothing runs them again on its next start" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} = start(session, [probe()], store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
      :ok = :gen_statem.stop(srv)

      {:ok, _srv2} = start(session, [probe()], store: {InMemory, store})
      assert_receive {:hook, :p, :on_session_start, _}
    end

    test "a crash under :reraise leaves the server :unavailable, replying the crash" do
      {:ok, srv} = start(sid(), [probe(returns: [on_session_start: {:raise, "crm down"}])])

      assert {:unavailable, _} = :sys.get_state(srv)

      assert {:error, {:handler_crashed, :on_session_start, %RuntimeError{message: "crm down"}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "a crash under :open is logged and the session starts without injection" do
      hooks = [probe(on_error: :open, returns: [on_session_start: {:raise, "crm down"}])]

      log =
        capture_log(fn ->
          {:ok, srv} = start(sid(), hooks)
          assert {:ok, _} = Turn.Server.run(srv, "hello")
        end)

      assert log =~ "on_session_start crashed: RuntimeError: crm down"
    end

    test "a store fault writing the injection leaves the server :unavailable" do
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]
      {:ok, srv} = start(sid(), hooks, store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:unavailable, _} = :sys.get_state(srv)
      assert {:error, {:persist_failed, :disk_full}} = Turn.Server.run(srv, "hello")
    end
  end

  describe "on_passivate" do
    test "runs when the idle server passivates; a crash still stops it normally" do
      # Linked by start_link and trapping exits, the test sees the stop reason however
      # soon passivation fires: no monitor to race.
      Process.flag(:trap_exit, true)

      {:ok, srv} =
        start(sid(), [probe(returns: [on_passivate: {:raise, "late"}])], idle_timeout_ms: 50)

      assert_receive {:hook, :p, :on_passivate, [%Normandy.Hooks.Context{event: :on_passivate}]},
                     1_000

      assert_receive {:EXIT, ^srv, :normal}, 1_000
    end
  end
end
