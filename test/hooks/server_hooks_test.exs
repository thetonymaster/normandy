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
  alias Normandy.TurnError

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

  # Crashes while the Agent registered as opts[:switch] holds :down; injects otherwise.
  defmodule FlakyProfile do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_session_start(_ctx, opts) do
      case Agent.get(opts[:switch], & &1) do
        :down -> raise "crm down"
        :up -> {:inject, ["profile: metric"]}
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
        toolset: nil,
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
               {:error,
                %TurnError{
                  type: :session_unavailable,
                  reason: {:invalid_hooks, "hook module Gone.Hook is not available"}
                }}

      assert Process.alive?(srv)
    end
  end

  describe "on_prompt" do
    test "a halt replies the HookHaltError, stores nothing and keeps the server" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} =
        start(session, [probe(returns: [on_prompt: {:halt, "off-topic"}])],
          store: {InMemory, store}
        )

      assert {:error,
              %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"}} =
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

    test "a hook crashing under :reraise replies a :handler_crashed TurnError; the server lives" do
      store = InMemory.new()
      session = sid()

      {:ok, srv} =
        start(session, [probe(returns: [on_prompt: {:raise, "redactor down"}])],
          store: {InMemory, store}
        )

      {_state, before} = :sys.get_state(srv)

      assert {:error,
              %TurnError{
                type: :handler_crashed,
                handler: :admit,
                reason: %RuntimeError{message: "redactor down"}
              }} = Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)

      assert {:error, %TurnError{type: :handler_crashed, handler: :admit}} =
               Turn.Server.run(srv, "again")

      {_state, data} = :sys.get_state(srv)
      assert data.config.memory == before.config.memory
      assert {:ok, []} = InMemory.history(store, session)
    end

    test "a throwing hook replies a :handler_crashed TurnError carrying the thrown term" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:throw, :redactor_gone}])])

      assert {:error, %TurnError{type: :handler_crashed, handler: :admit, reason: :redactor_gone}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "a plain-map rewrite the input schema rejects replies the ValidationError" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_prompt: {:cont, %{"query" => nil}}])]

      {:ok, srv} =
        start(session, hooks, store: {InMemory, store}, config: %{input_schema: %QueryInput{}})

      assert {:error, %Normandy.Schema.ValidationError{}} =
               Turn.Server.run(srv, %{"query" => "my ssn is 1"})

      assert {:ok, []} = InMemory.history(store, session)
    end

    test "a contract violation is replied the same way" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: :yes])])

      assert {:error,
              %TurnError{type: :handler_crashed, handler: :admit, reason: %ArgumentError{}}} =
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
          toolset: nil,
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
      refute_receive {:hook, :p, :on_turn_end, _}, 50
    end

    test "a turn that fails reports {:error, exception} exactly once" do
      boom = fn _config, _state, _request -> raise "client down" end
      {:ok, srv} = start(sid(), [probe()], handlers: %{call_llm: boom})

      assert {:error, %TurnError{type: :task_down} = error} = Turn.Server.run(srv, "hello")
      assert_receive {:hook, :p, :on_turn_end, [{:error, ^error}, _ctx]}
      refute_receive {:hook, :p, :on_turn_end, _}, 50
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

      assert {:error, %Normandy.Schema.ValidationError{}} = Turn.Server.run(srv, %{})

      assert_receive {:hook, :p, :on_turn_end,
                      [
                        {:rejected, %Normandy.Schema.ValidationError{}},
                        %Normandy.Hooks.Context{turn_id: nil}
                      ]}
    end

    test "an admission crash reports {:error, %TurnError{type: :handler_crashed}}" do
      {:ok, srv} = start(sid(), [probe(returns: [on_prompt: {:raise, "x"}])])

      assert {:error, %TurnError{type: :handler_crashed, handler: :admit} = error} =
               Turn.Server.run(srv, "hello")

      assert %RuntimeError{} = error.reason
      assert_receive {:hook, :p, :on_turn_end, [{:error, ^error}, _ctx]}
    end

    test "a failed write of the turn's first message reports a :persist_failed TurnError" do
      {:ok, srv} =
        start(sid(), [probe()], store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:error, %TurnError{type: :persist_failed, reason: :disk_full} = error} =
               Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end, [{:error, ^error}, _ctx]}
    end

    test "ServerGlue.fail_outcome/1: an output-guardrail block is a rejection, the rest errors" do
      e = %Normandy.Guardrails.ViolationError{message: "blocked", violations: []}
      assert ServerGlue.fail_outcome({:rejected, e}) == {:rejected, e}

      assert ServerGlue.fail_outcome({:approval_timeout, ["t"]}) ==
               {:error, %TurnError{type: :approval_timeout, reason: ["t"]}}

      h = %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget"}
      assert ServerGlue.fail_outcome({:hook_halted, h}) == {:error, h}
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

    test "a before_llm halt replies the HookHaltError and on_turn_end sees the same" do
      {:ok, srv} = start(sid(), [probe(returns: [before_llm: {:halt, "budget"}])])

      assert {:error,
              %Normandy.HookHaltError{event: :before_llm, hook: Probe, reason: "budget"} = e} =
               Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end, [{:error, ^e}, _ctx]}
      assert Process.alive?(srv)
    end

    test "a before_llm crash under :reraise replies a :handler_crashed TurnError" do
      {:ok, srv} = start(sid(), [probe(returns: [before_llm: {:raise, "budget down"}])])

      assert {:error,
              %TurnError{
                type: :handler_crashed,
                handler: :before_llm,
                reason: %RuntimeError{message: "budget down"}
              } = error} = Turn.Server.run(srv, "hello")

      assert_receive {:hook, :p, :on_turn_end, [{:error, ^error}, _ctx]}

      assert Process.alive?(srv)
    end

    test "a before_llm contract violation is replied the same way" do
      {:ok, srv} = start(sid(), [probe(returns: [before_llm: :yes])])

      assert {:error,
              %TurnError{type: :handler_crashed, handler: :before_llm, reason: %ArgumentError{}}} =
               Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "an LLM client crash is a :task_down TurnError, not a hook crash" do
      boom = fn _config, _state, _request -> raise "client down" end
      {:ok, srv} = start(sid(), [probe()], handlers: %{call_llm: boom})

      assert {:error, %TurnError{type: :task_down, reason: %RuntimeError{message: "client down"}}} =
               Turn.Server.run(srv, "hello")

      assert_received {:hook, :p, :before_llm, _}
      assert Process.alive?(srv)
    end

    test "an after_compact crash under :reraise replies a :handler_crashed TurnError" do
      hooks = [probe(returns: [after_compact: {:raise, "archive down"}])]

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, context_window: 200_000}
      }

      {:ok, srv} = start(sid(), hooks, config: %{behaviours: behaviours})

      assert {:ok, _} = Turn.Server.run(srv, "one")

      assert {:error,
              %TurnError{
                type: :handler_crashed,
                handler: :after_compact,
                reason: %RuntimeError{message: "archive down"}
              } = error} = Turn.Server.run(srv, "two")

      assert_receive {:hook, :p, :on_turn_end, [{:error, ^error}, _ctx]}

      assert Process.alive?(srv)
    end

    test "after a restart, after_compact reports the dropped messages again under the same ids" do
      store = InMemory.new()
      session = sid()
      hooks = [probe()]

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, context_window: 200_000}
      }

      opts = [store: {InMemory, store}, config: %{behaviours: behaviours}]
      {:ok, srv} = start(session, hooks, opts)

      assert {:ok, _} = Turn.Server.run(srv, "one")
      assert {:ok, _} = Turn.Server.run(srv, "two")
      assert_receive {:hook, :p, :after_compact, [dropped, _meta, _ctx]}
      ids = Enum.map(dropped, & &1.id)
      assert ids != []

      :ok = :gen_statem.stop(srv)
      {:ok, srv2} = start(session, hooks, opts)

      assert {:ok, _} = Turn.Server.run(srv2, "three")
      assert_receive {:hook, :p, :after_compact, [dropped_again, _meta, _ctx]}
      assert Enum.take(Enum.map(dropped_again, & &1.id), length(ids)) == ids
    end

    test "a compactor crash is a :task_down TurnError, not a hook crash" do
      hooks = [probe()]
      boom = fn _config, _state, _info -> raise "compactor down" end

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, context_window: 200_000}
      }

      {:ok, srv} =
        start(sid(), hooks, handlers: %{compact: boom}, config: %{behaviours: behaviours})

      assert {:error,
              %TurnError{type: :task_down, reason: %RuntimeError{message: "compactor down"}}} =
               Turn.Server.run(srv, "one")

      assert Process.alive?(srv)
    end

    test "after_compact gets dropped entries under their store ids; injections stay out of the store" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [after_compact: {:inject, ["remember: metric"]}])]

      behaviours = %Config{
        hooks: hooks,
        compactor: {KeepLastCompactor, keep: 1, context_window: 200_000}
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
    test "the stored injection keeps its memory id, through a turn and a restart" do
      store = InMemory.new()
      session = sid()
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]

      {:ok, srv} = start(session, hooks, store: {InMemory, store})
      {_state, data} = :sys.get_state(srv)
      assert {:ok, [%{id: id}]} = InMemory.history(store, session)
      assert id == data.config.memory.head

      assert {:ok, _} = Turn.Server.run(srv, "hello")
      {_state, data} = :sys.get_state(srv)
      live = data.config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)
      {:ok, stored} = InMemory.history(store, session)
      assert Enum.map(stored, & &1.id) == live

      :ok = :gen_statem.stop(srv)
      {:ok, srv2} = start(session, hooks, store: {InMemory, store})
      {_state, data2} = :sys.get_state(srv2)
      assert data2.config.memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id) == live
    end

    test "run/2 retries a failed session start; the injection is stored once and the turn runs" do
      store = InMemory.new()
      session = sid()
      switch = :"profile_switch_#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.start_link(fn -> :down end, name: switch)

      {:ok, srv} = start(session, [{FlakyProfile, switch: switch}], store: {InMemory, store})
      assert {:unavailable, _} = :sys.get_state(srv)

      Agent.update(switch, fn _ -> :up end)
      assert {:ok, %Resp{content: "hi"}} = Turn.Server.run(srv, "hello")

      assert {:ok,
              [
                %{role: "user", content: "profile: metric"},
                %{role: "user", content: "hello"},
                %{role: "assistant"}
              ]} = InMemory.history(store, session)
    end

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

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: %TurnError{
                  type: :handler_crashed,
                  handler: :on_session_start,
                  reason: %RuntimeError{message: "crm down"}
                }
              }} = Turn.Server.run(srv, "hello")

      assert Process.alive?(srv)
    end

    test "a crash under :open is logged and the session starts without injection" do
      hooks = [probe(on_error: :open, returns: [on_session_start: {:raise, "crm down"}])]

      log =
        capture_log(fn ->
          {:ok, srv} = start(sid(), hooks)
          assert {:ok, _} = Turn.Server.run(srv, "hello")
        end)

      assert log =~ "on_session_start crashed: RuntimeError"
      refute log =~ "crm down"
    end

    test "a store fault writing the injection leaves the server :unavailable" do
      hooks = [probe(returns: [on_session_start: {:inject, ["profile: metric"]}])]
      {:ok, srv} = start(sid(), hooks, store: {UserAppendFailStore, UserAppendFailStore.new()})

      assert {:unavailable, _} = :sys.get_state(srv)

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: %TurnError{type: :persist_failed, reason: :disk_full}
              }} = Turn.Server.run(srv, "hello")
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
