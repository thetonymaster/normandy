defmodule Normandy.Agents.Turn.SessionTest do
  use ExUnit.Case, async: true
  import Normandy.Test.Eventually
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.TurnConfig
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  # A local response struct for stubbing call_llm in Session tests.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes what it stores (AgentMemory.Entry's `wire`), so the fake answer
  # needs an encoding like any output schema.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # A store whose history/2 reports a genuine fault (a contract-permitted
  # {:error, _}), used to prove rehydration propagates it instead of crashing.
  defmodule FaultyStore do
    def load_turn_state(_handle, _sid), do: :error
    def history(_handle, _sid), do: {:error, :store_unavailable}
  end

  # A store whose turn-state load reports a backend fault.
  defmodule TurnStateFaultStore do
    def history(_handle, _sid), do: {:ok, []}
    def load_turn_state(_handle, _sid), do: {:error, :store_unavailable}
  end

  # A store whose config-template load reports a backend fault.
  defmodule TemplateFaultStore do
    def load_config_template(_handle, _sid), do: {:error, :store_unavailable}
  end

  # A store that refuses to save a config template.
  defmodule TemplateSaveFaultStore do
    def save_config_template(_handle, _sid, _tmpl), do: {:error, :disk_full}
  end

  # A supervisor stand-in that reports the server opts Session built, then refuses.
  defmodule CapturingSupervisor do
    @behaviour Normandy.Agents.Turn.ServerSupervisor

    def start_server(test_pid, opts) do
      send(test_pid, {:server_opts, opts})
      {:error, :captured}
    end

    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  defp session_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: AgentMemory.new_memory(),
      toolset: nil
    }
  end

  # A config a session with a :template_provider accepts: it names a credential provider.
  defp tier2_config do
    %{
      session_config()
      | behaviours: %Normandy.Behaviours.Config{credential: {Normandy.Test.StubCreds, []}}
    }
  end

  # A complete option list for new/1 that starts nothing.
  defp new_opts(extra \\ []) do
    Keyword.merge(
      [
        session_id: "s-new",
        config: session_config(),
        store: {InMemory, :store},
        registry: {Native, :reg},
        supervisor: :sup
      ],
      extra
    )
  end

  describe "new/1" do
    test "returns a %Turn.Session{} with the defaults filled in" do
      assert %Turn.Session{
               session_id: "s-new",
               store: {InMemory, :store},
               registry: {Native, :reg},
               supervisor: :sup,
               supervisor_mod: Turn.Supervisor,
               resume_policy: :lazy,
               template_provider: nil,
               template_id: nil,
               subscriber: nil,
               handlers: nil,
               server_options: []
             } = Turn.Session.new(new_opts())
    end

    # Only a session with both :config and :template_provider saves the config as a template
    # the server rebuilds from; :config alone (Tier 0/1) runs the config as given, and
    # :template_provider alone starts from a template already stored (checked on load).
    test "a template-backed session without a credential provider is refused at new/1" do
      tier2 = new_opts(template_provider: {Catalog, :cat})

      error = assert_raise ArgumentError, ~r/:credential/, fn -> Turn.Session.new(tier2) end
      assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
      assert error.message =~ "Normandy.Behaviours.CredentialProvider"

      with_creds =
        put_in(tier2[:config].behaviours, %Normandy.Behaviours.Config{
          credential: {Normandy.Test.StubCreds, []}
        })

      assert %Turn.Session{} = Turn.Session.new(with_creds)
      assert %Turn.Session{config: %{behaviours: nil}} = Turn.Session.new(new_opts())

      assert %Turn.Session{config: nil} =
               Turn.Session.new(Keyword.delete(tier2, :config))
    end

    defmodule StartOnlySupervisor do
      def start_server(_sup, _opts), do: {:error, :unused}
    end

    test "a :supervisor_mod that does not export the ServerSupervisor callbacks is refused" do
      for mod <- [StartOnlySupervisor, NoSuchSupervisorModule] do
        error =
          assert_raise ArgumentError, fn -> Turn.Session.new(new_opts(supervisor_mod: mod)) end

        assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
        assert error.message =~ ":supervisor_mod"
        assert error.message =~ "Normandy.Agents.Turn.ServerSupervisor"
      end

      assert %Turn.Session{supervisor_mod: Turn.Supervisor.Horde} =
               Turn.Session.new(new_opts(supervisor_mod: Turn.Supervisor.Horde))
    end

    test "keeps only the server options it was given" do
      assert %Turn.Session{server_options: [on_approval_timeout: :fail]} =
               Turn.Session.new(new_opts(on_approval_timeout: :fail))
    end

    test "requires :config or :template_provider" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.new/1: requires :config " <>
                     "(a %Normandy.Agents.BaseAgentConfig{}) or :template_provider " <>
                     "({module, handle}), got neither",
                   fn -> Turn.Session.new(Keyword.delete(new_opts(), :config)) end
    end

    test "a missing required key names the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(Keyword.delete(new_opts(), :store))
        end

      assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
      assert error.message =~ ":store"
    end

    test "a misspelled key names the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(new_opts(approval_timout_ms: 1))
        end

      assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
      assert error.message =~ ":approval_timout_ms"
    end

    test "a :config that is not a BaseAgentConfig is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(new_opts(config: %{client: %{api_key: "sk-secret"}}))
        end

      assert error.message =~ ":config"
      refute error.message =~ "sk-secret"
    end

    test ":resume_policy must be :lazy or :eager" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(new_opts(resume_policy: :sometimes))
        end

      assert error.message =~ ":resume_policy"
      assert error.message =~ ":sometimes"
    end

    test "something other than a keyword list is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.new/1: expected a keyword list, got: a map",
                   fn -> Turn.Session.new(%{session_id: "s"}) end
    end
  end

  describe "run/2, approve/2 and put_config/2" do
    test "run/2 and approve/2 reject an option list with a pointer to new/1" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.run/2: expected a %Normandy.Agents.Turn.Session{} " <>
                     "(build one with Normandy.Agents.Turn.Session.new/1), got: a list",
                   fn -> Turn.Session.run(new_opts(), "hi") end

      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.approve/2: expected a %Normandy.Agents.Turn.Session{} " <>
                     "(build one with Normandy.Agents.Turn.Session.new/1), got: a list",
                   fn -> Turn.Session.approve(new_opts(), %{}) end
    end

    test "put_config/2 replaces the config a later start uses" do
      session = Turn.Session.new(new_opts())
      config = %{session_config() | temperature: 0.42}

      assert %Turn.Session{config: ^config} = Turn.Session.put_config(session, config)

      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.put_config/2: expected a " <>
                     "%Normandy.Agents.BaseAgentConfig{}, got: a map",
                   fn -> Turn.Session.put_config(session, %{}) end
    end
  end

  test "supervisor starts a Turn.Server child as transient" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "x",
        config: TurnConfig.build(),
        store: {Normandy.Behaviours.SessionStore.InMemory, InMemory.new()},
        registry: {Normandy.Behaviours.SessionRegistry.Native, Native.new()}
      )

    assert is_pid(pid)
    assert [{:undefined, ^pid, :worker, _}] = DynamicSupervisor.which_children(sup)
  end

  test "routes to a live session, else rehydrates turn state + memory from the store" do
    alias Normandy.Behaviours.SessionRegistry.Native
    alias Normandy.Behaviours.SessionStore.InMemory

    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])

    # Pre-seed the store with a prior conversation entry (simulating a passivated session).
    {:ok, _} =
      InMemory.append_entry(store, "sess", %Normandy.Components.AgentMemory.Entry{
        turn_id: "t0",
        role: "user",
        content: "earlier"
      })

    opts = [
      session_id: "sess",
      config: session_config(),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
      }
    ]

    assert {:ok, %{content: "ok"}} = Turn.Session.run(Turn.Session.new(opts), "now")
    # Second call routes to the SAME live pid (no new child).
    assert {:ok, _} = Turn.Session.run(Turn.Session.new(opts), "again")
    assert length(DynamicSupervisor.which_children(sup)) == 1
  end

  describe "a supervisor restart after a crash" do
    @describetag :capture_log

    test "the restarted server reads turn state and memory from the store, not its first start" do
      store = InMemory.new()
      reg = Native.new()
      {:ok, sup} = Turn.Supervisor.start_link([])
      test_pid = self()

      opts = [
        session_id: "restart-#{System.unique_integer([:positive])}",
        config: session_config(),
        store: {InMemory, store},
        registry: {Native, reg},
        supervisor: sup,
        handlers: %{
          AgentHandlers.non_streaming_handlers()
          | call_llm: fn c, _s, _r ->
              send(test_pid, {:llm_memory, c.memory})
              %Resp{content: "ok"}
            end
        }
      ]

      sid = opts[:session_id]
      # A turn state that exists before the first start, so a restart that reuses
      # the first start's arguments would bring this one back.
      :ok = InMemory.save_turn_state(store, sid, %Turn.State{}, false)
      assert {:ok, _} = Turn.Session.run(Turn.Session.new(opts), "first message")
      assert_receive {:llm_memory, _}
      {:ok, pid} = Native.whereis(reg, sid)

      Process.exit(pid, :kill)

      assert wait_until(fn ->
               match?({:ok, new} when new != pid, Native.whereis(reg, sid))
             end)

      {:ok, restarted} = Native.whereis(reg, sid)
      {:ok, stored_state} = InMemory.load_turn_state(store, sid)
      refute stored_state == %Turn.State{}
      {_state, data} = :sys.get_state(restarted)
      assert data.turn_state == stored_state

      assert {:ok, _} = Turn.Session.run(Turn.Session.new(opts), "second message")
      assert_receive {:llm_memory, memory}
      contents = memory |> AgentMemory.messages() |> Enum.map(& &1.content)

      assert "first message" in contents,
             "restarted server lost the first turn; memory had #{inspect(contents)}"
    end
  end

  test "approve/2 returns a :session_unavailable TurnError for an unknown session" do
    session =
      Turn.Session.new(
        session_id: "ghost",
        config: session_config(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: self(),
        supervisor_mod: CapturingSupervisor
      )

    # No live session exists, so approval cannot succeed and must not boot one.
    assert {:error, %TurnError{type: :session_unavailable, reason: :no_session}} =
             Turn.Session.approve(session, %{})

    refute_received {:server_opts, _}
  end

  test "rehydration preserves the configured memory cap (max_messages)" do
    alias Normandy.Behaviours.SessionRegistry.Native
    alias Normandy.Behaviours.SessionStore.InMemory

    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])

    {:ok, _} =
      InMemory.append_entry(store, "capped", %Normandy.Components.AgentMemory.Entry{
        turn_id: "t0",
        role: "user",
        content: "earlier"
      })

    config = %{session_config() | memory: AgentMemory.new_memory(7)}

    opts = [
      session_id: "capped",
      config: config,
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
      }
    ]

    assert {:ok, _} = Turn.Session.run(Turn.Session.new(opts), "now")

    {:ok, pid} = Native.whereis(reg, "capped")
    {_state, data} = :sys.get_state(pid)
    assert data.config.memory.max_messages == 7
  end

  test "run/2 returns {:error, reason} when history/2 faults during rehydration" do
    alias Normandy.Behaviours.SessionRegistry.Native

    {:ok, sup} = Turn.Supervisor.start_link([])

    opts = [
      session_id: "faulty",
      config: session_config(),
      store: {FaultyStore, :ignored},
      registry: {Native, Native.new()},
      supervisor: sup
    ]

    # A store fault must surface as run/2's error tuple, not a caller crash.
    assert {:error, %TurnError{type: :session_unavailable, reason: :store_unavailable}} =
             Turn.Session.run(Turn.Session.new(opts), "hello")
  end

  defmodule DownRegistry do
    def whereis(_handle, _sid), do: {:error, :registry_down}
  end

  defmodule NoStartSupervisor do
    @behaviour Normandy.Agents.Turn.ServerSupervisor

    def start_server(_sup, _opts), do: raise("no server should be started")

    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  test "a registry lookup that fails is run/2's and approve/2's error; no server starts" do
    opts = [
      session_id: "registry-down",
      config: session_config(),
      store: {Normandy.Behaviours.SessionStore.InMemory, :unused},
      registry: {DownRegistry, nil},
      supervisor: :unused,
      supervisor_mod: NoStartSupervisor
    ]

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Turn.Session.run(Turn.Session.new(opts), "hello")

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Turn.Session.approve(Turn.Session.new(opts), %{})
  end

  test "run/2 returns {:error, reason} when the turn-state load faults during rehydration" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    opts = [
      session_id: "faulty-turn-state",
      config: session_config(),
      store: {TurnStateFaultStore, :ignored},
      registry: {Native, Native.new()},
      supervisor: sup
    ]

    # A fault is not "no saved turn": starting fresh would drop an in-flight turn.
    assert {:error, %TurnError{type: :session_unavailable, reason: :store_unavailable}} =
             Turn.Session.run(Turn.Session.new(opts), "hello")
  end

  test "run/2 forwards :on_approval_timeout to the server" do
    alias Normandy.Behaviours.SessionRegistry.Native

    opts = [
      session_id: "s-fwd",
      config: session_config(),
      store: {InMemory, InMemory.new()},
      registry: {Native, Native.new()},
      supervisor: self(),
      supervisor_mod: CapturingSupervisor,
      on_approval_timeout: :fail
    ]

    assert {:error, %TurnError{type: :session_unavailable, reason: :captured}} =
             Turn.Session.run(Turn.Session.new(opts), "hi")

    assert_received {:server_opts, server_opts}
    assert Keyword.fetch!(server_opts, :on_approval_timeout) == :fail
  end

  test "a Tier-2 start saves the server options with the config template" do
    store = InMemory.new()
    {:ok, cat} = Catalog.start_link([])

    opts = [
      session_id: "s-server-opts",
      config: tier2_config(),
      store: {InMemory, store},
      registry: {Native, Native.new()},
      supervisor: self(),
      supervisor_mod: CapturingSupervisor,
      template_provider: {Catalog, cat},
      approval_timeout_ms: 1_234,
      on_approval_timeout: :fail,
      idle_timeout_ms: 5_000
    ]

    assert {:error, %TurnError{type: :session_unavailable, reason: :captured}} =
             Turn.Session.run(Turn.Session.new(opts), "hi")

    assert {:ok, tmpl} = InMemory.load_config_template(store, "s-server-opts")

    assert tmpl.server_options == %{
             approval_timeout_ms: 1_234,
             on_approval_timeout: :fail,
             idle_timeout_ms: 5_000
           }
  end

  test "a Tier-2 start returns the store's error when the template cannot be saved" do
    {:ok, cat} = Catalog.start_link([])

    opts = [
      session_id: "s-save-fault",
      config: tier2_config(),
      store: {TemplateSaveFaultStore, nil},
      registry: {Native, Native.new()},
      supervisor: self(),
      supervisor_mod: CapturingSupervisor,
      template_provider: {Catalog, cat}
    ]

    assert {:error, %TurnError{type: :session_unavailable, reason: :disk_full}} =
             Turn.Session.run(Turn.Session.new(opts), "hi")

    refute_received {:server_opts, _}
  end

  describe "resume_policy: :eager" do
    test "a Tier-2 start saves it in the template; the session is listed only once a turn is in flight" do
      store = InMemory.new()
      {:ok, cat} = Catalog.start_link([])

      opts = [
        session_id: "s-eager",
        config: tier2_config(),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        supervisor: self(),
        supervisor_mod: CapturingSupervisor,
        template_provider: {Catalog, cat},
        resume_policy: :eager
      ]

      assert {:error, %TurnError{type: :session_unavailable, reason: :captured}} =
               Turn.Session.run(Turn.Session.new(opts), "hi")

      assert {:ok, %{resume_policy: :eager}} = InMemory.load_config_template(store, "s-eager")
      # No turn ran (the supervisor refused the start), so nothing is in flight.
      assert {:ok, []} = InMemory.list_resumable(store)
    end

    test "a Tier 0/1 start passes it to the server" do
      opts = [
        session_id: "s-eager-local",
        config: session_config(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: self(),
        supervisor_mod: CapturingSupervisor,
        resume_policy: :eager
      ]

      assert {:error, %TurnError{type: :session_unavailable, reason: :captured}} =
               Turn.Session.run(Turn.Session.new(opts), "hi")

      assert_received {:server_opts, server_opts}
      assert server_opts[:resume_policy] == :eager
    end
  end

  test "concurrent ensure-server for one session resolves to a single pid (Horde via)" do
    alias Normandy.Behaviours.SessionRegistry.Horde
    alias Normandy.Behaviours.SessionStore.InMemory

    reg = Horde.new()
    store = InMemory.new()
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    sid = "race-#{System.unique_integer([:positive])}"

    opts = [
      session_id: sid,
      config: session_config(),
      store: {InMemory, store},
      registry: {Horde, reg},
      supervisor: sup,
      handlers: %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
      }
    ]

    results =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Normandy.Agents.Turn.Session.run(Normandy.Agents.Turn.Session.new(opts), nil)
        end)
      end)
      |> Enum.map(&Task.await(&1, 5000))

    # All callers succeed and route to the one registered server (Horde registration
    # is eventually consistent; poll until visible).
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert wait_until(fn -> match?({:ok, _}, Horde.whereis(reg, sid)) end)
    {:ok, pid} = Horde.whereis(reg, sid)
    assert [_one] = children_pids(sup) |> Enum.uniq()
    assert is_pid(pid)
  end

  test "Tier-2 thin path rehydrates conversation history into reconstructed server memory" do
    # Part C: proves that a thin start loads session history so a
    # rehydrated/redistributed Tier-2 server does NOT start with empty memory.
    # Without Part B (the history load in Turn.Server.with_stored_memory/3) the captured
    # memory would have 0 messages and the assertion below would fail — that is
    # the RED justification for this test.
    alias Normandy.Behaviours.SessionRegistry.Native
    alias Normandy.Behaviours.SessionStore.InMemory
    alias Normandy.Test.TurnConfig

    test_pid = self()
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    sid = "tier2-hist-#{System.unique_integer([:positive])}"

    # Pre-seed the store with a prior conversation entry (simulating passivation).
    {:ok, _} =
      InMemory.append_entry(store, sid, %Normandy.Components.AgentMemory.Entry{
        turn_id: "t-prior",
        role: "user",
        content: "remember-me"
      })

    {:ok, _} =
      InMemory.append_entry(store, sid, %Normandy.Components.AgentMemory.Entry{
        turn_id: "t-prior",
        role: "assistant",
        content: "got it"
      })

    # Build a config and register its supplement in the Catalog.
    config = TurnConfig.build()

    {:ok, cat} = Catalog.start_link([])

    :ok =
      Catalog.put(cat, "tier2-k", %{
        toolset: config.toolset,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> config.client end
      })

    # Stub call_llm: capture the config memory at call time, reply via message.
    handlers = %{
      AgentHandlers.non_streaming_handlers()
      | call_llm: fn c, _s, _r ->
          send(test_pid, {:captured_memory, c.memory})
          %TurnConfig.Resp{content: "ok"}
        end
    }

    opts = [
      session_id: sid,
      config: config,
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      template_provider: {Catalog, cat},
      template_id: "tier2-k",
      handlers: handlers
    ]

    # The Tier-2 path: Session saves a template (no :config to the server),
    # server reconstructs from template + store history.
    assert {:ok, _} =
             Normandy.Agents.Turn.Session.run(Normandy.Agents.Turn.Session.new(opts), "hello")

    # Assert: the LLM call saw the pre-seeded history (not empty memory).
    assert_receive {:captured_memory, memory}, 2000

    messages = AgentMemory.messages(memory)
    contents = Enum.map(messages, & &1.content)

    assert "remember-me" in contents,
           "Tier-2 reconstruct loaded empty memory — history rehydration is broken. " <>
             "Got contents: #{inspect(contents)}"
  end

  describe "a template-backed session without :config" do
    alias Normandy.Test.TurnConfig

    defp template_opts(store, sid) do
      config = TurnConfig.build()
      {:ok, cat} = Catalog.start_link([])
      {:ok, sup} = Turn.Supervisor.start_link([])

      :ok =
        Catalog.put(cat, "kind", %{
          toolset: config.toolset,
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> config.client end
        })

      [
        session_id: sid,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        supervisor: sup,
        template_provider: {Catalog, cat},
        handlers: %{
          AgentHandlers.non_streaming_handlers()
          | call_llm: fn _c, _s, _r -> %TurnConfig.Resp{content: "from template"} end
        }
      ]
    end

    test "starts from the template saved in the store" do
      store = InMemory.new()
      sid = "tmpl-#{System.unique_integer([:positive])}"
      tmpl = ConfigTemplate.from_config(TurnConfig.build(), "kind")
      :ok = InMemory.save_config_template(store, sid, tmpl)

      assert {:ok, %{content: "from template"}} =
               Turn.Session.run(Turn.Session.new(template_opts(store, sid)), "hello")

      assert {:ok, ^tmpl} = InMemory.load_config_template(store, sid)
    end

    test "a template-load fault is returned, not reported as a missing template" do
      sid = "tmpl-fault-#{System.unique_integer([:positive])}"
      opts = Keyword.put(template_opts(InMemory.new(), sid), :store, {TemplateFaultStore, nil})

      assert {:error, %TurnError{type: :session_unavailable, reason: :store_unavailable}} =
               Turn.Session.run(Turn.Session.new(opts), "hello")
    end

    test "with no saved template it returns an error" do
      store = InMemory.new()
      sid = "no-tmpl-#{System.unique_integer([:positive])}"

      assert {:error, %TurnError{type: :session_unavailable, reason: {:no_config_template, ^sid}}} =
               Turn.Session.run(Turn.Session.new(template_opts(store, sid)), "hello")
    end
  end

  describe "tool context after rehydration" do
    alias Normandy.Components.ToolCall
    alias Normandy.Test.{ContextProbe, TurnConfig}
    alias Normandy.Tools.Context

    # First LLM call of a turn asks for the probe; once a tool result is the last
    # message, it answers.
    defp probe_handlers do
      %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn c, _s, _r ->
            case c.memory |> AgentMemory.messages() |> List.last() do
              %{role: "tool"} ->
                %TurnConfig.Resp{content: "done"}

              _ ->
                id = "call-#{System.unique_integer([:positive])}"

                %TurnConfig.Resp{
                  content: "",
                  tool_calls: [%ToolCall{id: id, name: "probe", input: %{}}]
                }
            end
          end
      }
    end

    defp fresh_node_opts(base) do
      {:ok, sup} = Turn.Supervisor.start_link([])

      base
      |> Keyword.delete(:config)
      |> Keyword.put(:supervisor, sup)
      |> Keyword.put(:registry, {Native, Native.new()})
    end

    test "two sessions of one template keep their own tool_context on a fresh node" do
      store = InMemory.new()
      {:ok, cat} = Catalog.start_link([])
      {:ok, sup} = Turn.Supervisor.start_link([])
      reg = Native.new()

      :ok =
        Catalog.put(cat, "mem-kind", %{
          toolset: Toolset.new([%ContextProbe{notify: self()}]),
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> %{api_key: "k"} end
        })

      base = fn sid, ns ->
        [
          session_id: sid,
          config: %{TurnConfig.build() | tool_context: %{memory_namespace: ns}},
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup,
          template_provider: {Catalog, cat},
          template_id: "mem-kind",
          handlers: probe_handlers()
        ]
      end

      sid_a = "ctx-a-#{System.unique_integer([:positive])}"
      sid_b = "ctx-b-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Turn.Session.run(Turn.Session.new(base.(sid_a, "acme/a")), "hi")

      assert_receive {:probe_ctx,
                      %Context{session_id: ^sid_a, values: %{memory_namespace: "acme/a"}}},
                     2000

      assert {:ok, _} = Turn.Session.run(Turn.Session.new(base.(sid_b, "acme/b")), "hi")

      assert_receive {:probe_ctx,
                      %Context{session_id: ^sid_b, values: %{memory_namespace: "acme/b"}}},
                     2000

      # A fresh supervisor and registry: no live server, so each session is rebuilt from
      # its stored template + the shared supplement, as on another node.
      assert {:ok, _} =
               Turn.Session.run(
                 Turn.Session.new(fresh_node_opts(base.(sid_a, "ignored"))),
                 "again"
               )

      assert_receive {:probe_ctx,
                      %Context{session_id: ^sid_a, values: %{memory_namespace: "acme/a"}}},
                     2000

      assert {:ok, _} =
               Turn.Session.run(
                 Turn.Session.new(fresh_node_opts(base.(sid_b, "ignored"))),
                 "again"
               )

      assert_receive {:probe_ctx,
                      %Context{session_id: ^sid_b, values: %{memory_namespace: "acme/b"}}},
                     2000
    end
  end

  defp children_pids(sup) do
    DynamicSupervisor.which_children(sup) |> Enum.map(fn {_, p, _, _} -> p end)
  end
end
