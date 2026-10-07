defmodule Normandy.Agents.Turn.ServerStoreFailuresTest do
  @moduledoc """
  Task 6.2a (PERF-7, Review Focus #2): a session store that exits, and a load that
  raises, exits or throws, never crash `Turn.Server`. In-turn writes fail the turn
  `:persist_failed` with `{:store_exit, reason}`; a load leaves the server `:unavailable`
  replying `:session_unavailable`. Every server runs under a `Turn.Supervisor` with
  `max_restarts: 0`, so one restart would stop the supervisor.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ConfigTemplate, Turn}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.ScriptedToolClient
  alias Normandy.Test.StubClient
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  # InMemory, except that the operations in the switch exit the way a timed-out
  # GenServer.call does, with the call's message (the entry being written) in the reason.
  # Handle: {in_memory_pid, switch_agent}. An op is :history, :load_turn_state,
  # :save_turn_state or {:append_entry, role}.
  defmodule ExitingStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def new do
      {:ok, switch} = Agent.start_link(fn -> MapSet.new() end)
      {InMemory.new(), switch}
    end

    def exit_on({_mem, switch}, ops), do: Agent.update(switch, fn _ -> MapSet.new(ops) end)

    def append_entry({mem, _} = h, sid, entry) do
      maybe_exit(h, {:append_entry, entry.role}, {:append_entry, sid, entry})
      InMemory.append_entry(mem, sid, entry)
    end

    def history({mem, _} = h, sid) do
      maybe_exit(h, :history, {:history, sid})
      InMemory.history(mem, sid)
    end

    def load_turn_state({mem, _} = h, sid) do
      maybe_exit(h, :load_turn_state, {:load_turn_state, sid})
      InMemory.load_turn_state(mem, sid)
    end

    def save_turn_state({mem, _} = h, sid, ts, inflight?) do
      maybe_exit(h, :save_turn_state, {:save_turn_state, sid, ts})
      InMemory.save_turn_state(mem, sid, ts, inflight?)
    end

    defp maybe_exit({_mem, switch}, op, message) do
      if MapSet.member?(Agent.get(switch, & &1), op),
        do: exit({:timeout, {GenServer, :call, [:store, message, 5000]}})
    end
  end

  # InMemory, except that the operations in the switch return the store's own error,
  # whose reason carries SQL text (as a Postgrex.Error's query does). Handle:
  # {in_memory_pid, switch_agent}; ops as ExitingStore's.
  defmodule ErroringStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    @reason {:sql, "SELECT secret_token FROM vault WHERE id = 7", %{"password" => "hunter2"}}

    def reason, do: @reason

    def new do
      {:ok, switch} = Agent.start_link(fn -> MapSet.new() end)
      {InMemory.new(), switch}
    end

    def fail_on({_mem, switch}, ops), do: Agent.update(switch, fn _ -> MapSet.new(ops) end)

    def append_entry({mem, _} = h, sid, entry) do
      if failing?(h, {:append_entry, entry.role}),
        do: {:error, @reason},
        else: InMemory.append_entry(mem, sid, entry)
    end

    def history({mem, _}, sid), do: InMemory.history(mem, sid)
    def load_turn_state({mem, _}, sid), do: InMemory.load_turn_state(mem, sid)

    def save_turn_state({mem, _} = h, sid, ts, inflight?) do
      if failing?(h, :save_turn_state),
        do: {:error, @reason},
        else: InMemory.save_turn_state(mem, sid, ts, inflight?)
    end

    defp failing?({_mem, switch}, op), do: MapSet.member?(Agent.get(switch, & &1), op)
  end

  # A store whose history read fails with a reason carrying a secret and a query.
  defmodule LeakyReasonStore do
    @moduledoc false
    def history(_h, _sid),
      do: {:error, {:query_failed, %{"password" => "hunter2"}, "SELECT secret FROM keys"}}

    def load_turn_state(_h, _sid), do: :error
  end

  # A store whose template read and write fail with a reason carrying a connection string.
  defmodule LeakyTemplateStore do
    @moduledoc false
    def load_config_template(_h, _sid), do: {:error, {:db_down, %{"dsn" => "postgres://u:pw@h"}}}

    def save_config_template(_h, _sid, _t),
      do: {:error, {:db_down, %{"dsn" => "postgres://u:pw@h"}}}
  end

  defmodule ExitingProvider do
    @moduledoc false
    def fetch(_handle, _template_id), do: exit(:provider_down)
  end

  defmodule ThrowingCreds do
    @moduledoc false
    @behaviour Normandy.Behaviours.CredentialProvider
    @impl true
    def get_token(_provider, _opts), do: throw(:vault_sealed)
  end

  @secret "my secret words"

  defp sup do
    {:ok, sup} = Turn.Supervisor.start_link(max_restarts: 0)
    sup
  end

  defp sid(tag), do: "#{tag}-#{System.unique_integer([:positive])}"

  defp start(sup, sid, store, reg, tools? \\ false) do
    {:ok, srv} =
      Turn.Supervisor.start_server(sup,
        session_id: sid,
        config: start_config(tools?),
        store: store,
        registry: {Native, reg}
      )

    srv
  end

  defp start_config(false), do: BaseAgent.init(%{client: %StubClient{}, model: "m"})

  # One tool round: the turn persists its :steering state after the batch.
  defp start_config(true) do
    client = %ScriptedToolClient{calls: [%ToolCall{id: "call_1", name: "big", input: %{}}]}

    %{client: client, model: "m"}
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ReturnTool{output: "ok"})
  end

  describe "in-turn writes" do
    test "an append that exits fails the turn :persist_failed; the same server runs the next turn" do
      sup = sup()
      reg = Native.new()
      {mem, _} = store = ExitingStore.new()
      sid = sid("append-exit")
      srv = start(sup, sid, {ExitingStore, store}, reg)

      ExitingStore.exit_on(store, [{:append_entry, "assistant"}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error,
                  %TurnError{
                    type: :persist_failed,
                    reason: {:store_exit, {:timeout, {GenServer, :call, 3}}}
                  } = error} = Turn.Server.run(srv, %{chat_message: @secret})

          refute inspect(error) =~ @secret
        end)

      refute log =~ @secret
      assert Process.alive?(srv)
      assert Process.alive?(sup)
      assert Native.whereis(reg, sid) == {:ok, srv}

      assert {:ok, %Turn.State{status: :failed, error: persisted}} =
               InMemory.load_turn_state(mem, sid)

      refute inspect(persisted) =~ @secret
      refute contains_stacktrace?(persisted)

      ExitingStore.exit_on(store, [])
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "again"})
      assert Native.whereis(reg, sid) == {:ok, srv}
    end

    test "a user-message append that exits replies :persist_failed before the turn starts" do
      sup = sup()
      store = ExitingStore.new()
      srv = start(sup, sid("user-exit"), {ExitingStore, store}, Native.new())

      ExitingStore.exit_on(store, [{:append_entry, "user"}])

      assert {:error, %TurnError{type: :persist_failed, reason: {:store_exit, {:timeout, _}}}} =
               Turn.Server.run(srv, %{chat_message: @secret})

      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end

    test "a terminal-state save that exits after a successful turn still replies {:ok, _}" do
      sup = sup()
      store = ExitingStore.new()
      srv = start(sup, sid("finalize-exit"), {ExitingStore, store}, Native.new())

      ExitingStore.exit_on(store, [:save_turn_state])

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end
  end

  describe "a store's own error reason in a turn" do
    setup do
      id = "store-reason-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          id,
          [[:normandy, :agent, :run, :exception], [:normandy, :agent, :run, :stop]],
          &__MODULE__.forward_event/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    # Every in-turn write site: the user message before the turn starts, an append
    # inside the turn, and the turn-state save after a tool batch (the one a turn fails
    # on; a terminal save is best-effort).
    for {label, op, tools?, persisted?} <- [
          {"the user-message append", {:append_entry, "user"}, false, false},
          {"an in-turn append", {:append_entry, "assistant"}, false, true},
          {"a turn-state save", :save_turn_state, true, false}
        ] do
      test "#{label} that fails replies, persists, logs and emits the reason by its tags only" do
        sup = sup()
        {mem, _} = store = ErroringStore.new()
        sid = sid("store-reason")
        srv = start(sup, sid, {ErroringStore, store}, Native.new(), unquote(tools?))

        ErroringStore.fail_on(store, [unquote(Macro.escape(op))])

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error,
                    %TurnError{
                      type: :persist_failed,
                      reason: {:sql, "a string (" <> _, "a map"}
                    } = error} = Turn.Server.run(srv, %{chat_message: "hi"})

            refute inspect(error, limit: :infinity) =~ "secret_token"
            refute inspect(error, limit: :infinity) =~ "hunter2"
            refute Exception.message(error) =~ "secret_token"
          end)

        refute log =~ "secret_token"
        refute log =~ "hunter2"

        assert_received {:telemetry, [:normandy, :agent, :run, _], %{session_id: ^sid} = meta}
        refute inspect(meta, limit: :infinity) =~ "secret_token"
        refute inspect(meta, limit: :infinity) =~ "hunter2"

        if unquote(persisted?) do
          assert {:ok, %Turn.State{status: :failed, error: persisted}} =
                   InMemory.load_turn_state(mem, sid)

          assert %TurnError{type: :persist_failed, reason: {:sql, _, "a map"}} = persisted
          refute inspect(persisted, limit: :infinity) =~ "secret_token"
        end

        assert Process.alive?(srv)
      end
    end
  end

  def forward_event(event, _measurements, metadata, pid),
    do: send(pid, {:telemetry, event, metadata})

  describe "the load" do
    test "a history read that exits leaves the server :unavailable until the store answers" do
      sup = sup()
      store = ExitingStore.new()
      ExitingStore.exit_on(store, [:history])
      srv = start(sup, sid("load-exit"), {ExitingStore, store}, Native.new())
      ref = Process.monitor(srv)

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: {:store_exit, {:timeout, {GenServer, :call, 3}}}
              }} = Turn.Server.run(srv, %{chat_message: "hi"})

      assert {:unavailable, _} = :sys.get_state(srv)

      # The :unavailable retry runs the same load: it exits again, and the server stays.
      assert {:error, %TurnError{type: :session_unavailable}} =
               Turn.Server.run(srv, %{chat_message: "hi"})

      refute_received {:DOWN, ^ref, :process, _, _}

      ExitingStore.exit_on(store, [])
      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "hi"})
      assert Process.alive?(sup)
    end

    test "a store's load reason is replied by its tags, never its terms" do
      srv = start(sup(), sid("leaky"), {LeakyReasonStore, nil}, Native.new())

      assert {:error,
              %TurnError{
                type: :session_unavailable,
                reason: {:query_failed, "a map", "a string (23 bytes)"}
              } = error} = Turn.Server.run(srv, %{chat_message: "hi"})

      refute inspect(error) =~ "hunter2"
      refute inspect(error) =~ "SELECT"
    end

    test "Turn.Session.run/2 reduces a store's template reasons the same way" do
      {:ok, cat} = Catalog.start_link([])

      base = [
        session_id: sid("leaky-template"),
        store: {LeakyTemplateStore, nil},
        registry: {Native, Native.new()},
        supervisor: sup(),
        template_provider: {Catalog, cat}
      ]

      # Thin (no :config): the template read fails. Tier 2 with a config: the save fails.
      for opts <- [base, Keyword.put(base, :config, TurnConfig.build())] do
        assert {:error,
                %TurnError{type: :session_unavailable, reason: {:db_down, "a map"}} = error} =
                 Turn.Session.run(Turn.Session.new(opts), %{chat_message: "hi"})

        refute inspect(error) =~ "pw@h"
      end
    end

    for {name, setup} <- [
          {"a template provider that exits", :provider_exits},
          {"a client_builder that raises", :builder_raises},
          {"a credential provider that throws", :creds_throw}
        ] do
      test "#{name} leaves the server :unavailable and alive" do
        sup = sup()
        {opts, expected} = thin_start(unquote(setup))
        {:ok, srv} = Turn.Supervisor.start_server(sup, opts)
        ref = Process.monitor(srv)

        assert {:error, %TurnError{type: :session_unavailable, reason: reason} = error} =
                 Turn.Server.run(srv, %{chat_message: "hi"})

        assert expected.(reason)
        refute contains_stacktrace?(error)
        assert {:unavailable, _} = :sys.get_state(srv)
        refute_received {:DOWN, ^ref, :process, _, _}
        assert Process.alive?(sup)
      end
    end

    test "a stored entry that cannot be encoded leaves the server :unavailable, its log clean" do
      sup = sup()
      store = InMemory.new()
      sid = sid("unencodable")
      entry = %Entry{id: "e1", turn_id: "t1", role: "user", content: {:opaque, @secret, self()}}
      {:ok, _} = InMemory.append_entry(store, sid, entry)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          srv = start(sup, sid, {InMemory, store}, Native.new())

          assert {:error,
                  %TurnError{type: :session_unavailable, reason: %Protocol.UndefinedError{}}} =
                   Turn.Server.run(srv, %{chat_message: "hi"})

          assert {:unavailable, _} = :sys.get_state(srv)
          assert Process.alive?(srv)
        end)

      assert Process.alive?(sup)
      refute log =~ @secret
      assert InMemory.load_turn_state(store, sid) == :error
    end

    test "a saved template with a bad :on_approval_timeout is refused like a bad template" do
      {opts, _expected} = thin_start(:bad_server_option)
      {:ok, srv} = Turn.Supervisor.start_server(sup(), opts)

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, %{chat_message: "hi"})

      assert message =~ ":on_approval_timeout must be :continue or :fail"
    end
  end

  describe "format_status" do
    test ":sys.get_status/1 shows the session id, never the conversation" do
      store = InMemory.new()
      sid = sid("status")
      srv = start(sup(), sid, {InMemory, store}, Native.new())

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: @secret})

      status = inspect(:sys.get_status(srv), limit: :infinity, printable_limit: :infinity)
      assert status =~ sid
      refute status =~ @secret
      refute status =~ "BaseAgentConfig"
    end

    # Final review M-a: a bug crash's reason can hold the entry being written, in a
    # function_clause frame's args or in a raised exception's fields.
    test "a crash reason keeps no stacktrace args and no foreign exception's fields" do
      frames = [{Normandy.Agents.Turn.Server, :append, [%{content: @secret}], [line: 1]}]

      for reason <- [
            {:function_clause, frames},
            {%RuntimeError{message: @secret}, frames},
            {:shutdown, {%ArgumentError{message: @secret}, frames}}
          ] do
        status = Turn.Server.format_status(%{reason: reason, data: :x, queue: [], log: []})
        refute inspect(status, limit: :infinity, printable_limit: :infinity) =~ @secret
      end

      assert %{reason: :function_clause} =
               Turn.Server.format_status(%{reason: {:function_clause, frames}})

      assert %{reason: :normal} = Turn.Server.format_status(%{reason: :normal})
    end
  end

  # {start options, a predicate on the replied reason} for a thin start whose load fails.
  defp thin_start(kind) do
    store = InMemory.new()
    sid = sid("thin-#{kind}")
    base = TurnConfig.build()
    {:ok, cat} = Catalog.start_link([])

    :ok = InMemory.save_config_template(store, sid, thin_template(kind, base))

    :ok =
      Catalog.put(cat, "kind-a", %{
        toolset: base.toolset,
        before_hooks: [],
        after_hooks: [],
        client_builder: thin_builder(kind, base)
      })

    provider = if kind == :provider_exits, do: {ExitingProvider, nil}, else: {Catalog, cat}

    opts = [
      session_id: sid,
      store: {InMemory, store},
      registry: {Native, Native.new()},
      template_provider: provider
    ]

    {opts, thin_expected(kind)}
  end

  defp thin_template(:creds_throw, base),
    do:
      put_in(
        ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
        {ThrowingCreds, []}
      )

  defp thin_template(:bad_server_option, base),
    do:
      Map.put(ConfigTemplate.from_config(base, "kind-a"), :server_options, %{
        on_approval_timeout: :sometimes
      })

  defp thin_template(_kind, base), do: ConfigTemplate.from_config(base, "kind-a")

  defp thin_builder(:builder_raises, _base), do: fn _token -> raise "builder bug" end
  defp thin_builder(_kind, base), do: fn _token -> base.client end

  defp thin_expected(:provider_exits), do: &(&1 == :provider_down)
  defp thin_expected(:builder_raises), do: &match?(%RuntimeError{message: "builder bug"}, &1)
  defp thin_expected(:creds_throw), do: &(&1 == :vault_sealed)
  defp thin_expected(:bad_server_option), do: &match?({:invalid_template, _}, &1)

  # A stacktrace is a list whose first element is an {module, function, arity_or_args, location} frame.
  defp contains_stacktrace?([{m, f, a, loc} | _])
       when is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) and is_list(loc),
       do: true

  defp contains_stacktrace?(list) when is_list(list), do: Enum.any?(list, &contains_stacktrace?/1)

  defp contains_stacktrace?(tuple) when is_tuple(tuple),
    do: contains_stacktrace?(Tuple.to_list(tuple))

  defp contains_stacktrace?(%_{} = struct), do: contains_stacktrace?(Map.from_struct(struct))
  defp contains_stacktrace?(map) when is_map(map), do: contains_stacktrace?(Map.to_list(map))
  defp contains_stacktrace?(_term), do: false
end
