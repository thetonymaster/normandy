defmodule Normandy.Agents.Turn.ServerErrorsTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ConfigTemplate, ToolCallResponse, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.ToolCall
  alias Normandy.LLMError
  alias Normandy.Test.TurnConfig
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  # Starts the server like Turn.Supervisor.start_server/2 but without its caller-side
  # option check, so a raise in Turn.Server.start_link/1 comes back as the
  # DynamicSupervisor's {:error, {exception, stacktrace}}.
  defmodule UncheckedSupervisor do
    @moduledoc false
    @behaviour Normandy.Agents.Turn.ServerSupervisor

    def start_server(sup, server_opts) do
      DynamicSupervisor.start_child(sup, %{
        id: Normandy.Agents.Turn.Server,
        start: {Normandy.Agents.Turn.Server, :start_link, [server_opts]},
        restart: :transient,
        type: :worker
      })
    end

    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  # A store whose history read fails: the server starts :unavailable.
  defmodule DownStore do
    @moduledoc false
    def history(_handle, _sid), do: {:error, :store_down}
    def load_turn_state(_handle, _sid), do: {:error, :store_down}
    def save_turn_state(_handle, _sid, _ts, _inflight?), do: {:error, :store_down}
    def append_entry(_handle, _sid, _entry), do: {:error, :store_down}
  end

  # The first call asks for the weather tool; the second, after the tool ran, gets a 429.
  defp tool_then_429_client do
    calls = :counters.new(1, [])

    %Normandy.Test.StubClient{
      reply: fn _response_model ->
        :counters.add(calls, 1, 1)

        case :counters.get(calls, 1) do
          1 ->
            %ToolCallResponse{
              content: nil,
              tool_calls: [%ToolCall{id: "call_1", name: "weather", input: %{"city" => "Paris"}}]
            }

          _ ->
            {:error, LLMError.new(type: :rate_limit, retryable?: true, status: 429)}
        end
      end
    }
  end

  defp start_server(sid, config, store) do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: store,
        registry: {Native, Native.new()}
      )

    srv
  end

  test "a 429 after tools ran replies the bare LLMError and leaves no stacktrace anywhere" do
    sid = "s-429-#{System.unique_integer([:positive])}"
    store = InMemory.new()

    config =
      BaseAgent.init(%{
        client: tool_then_429_client(),
        model: "m",
        toolset: Toolset.new([%Normandy.Test.FakeTool{notify: self()}])
      })

    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :run, :exception]])
    srv = start_server(sid, config, {InMemory, store})

    assert {:error, %LLMError{type: :rate_limit, status: 429}} =
             Turn.Server.run(srv, %{chat_message: "weather in Paris?"})

    assert_received {:tool_ran, "weather"}
    assert Process.alive?(srv)

    assert {:ok, turn_state} = InMemory.load_turn_state(store, sid)
    refute contains_stacktrace?(turn_state)

    assert_received {[:normandy, :agent, :run, :exception], ^ref, _,
                     %{kind: :error, reason: %LLMError{type: :rate_limit}, stacktrace: []}}
  end

  test "a handler exit carrying a stacktrace is replied and persisted without it" do
    sid = "s-exit-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    e = %RuntimeError{message: "store process raised"}
    frames = [{Some.Store, :append, 3, [file: ~c"store.ex", line: 1]}]

    # A GenServer.call to a process that raised exits with {{e, stacktrace}, {mod, fun, args}}.
    append = fn _config, _role, _content ->
      exit({{e, frames}, {GenServer, :call, [:store, :append, 5000]}})
    end

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}),
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | append: append}
      )

    assert {:error, %TurnError{type: :handler_crashed, handler: :append, reason: reason}} =
             Turn.Server.run(srv, %{chat_message: "hi"})

    assert {^e, {GenServer, :call, _}} = reason
    assert {:ok, turn_state} = InMemory.load_turn_state(store, sid)
    assert turn_state.status == :failed
    refute contains_stacktrace?(turn_state)
    assert Process.alive?(srv)
  end

  test "a session whose store is down replies a :session_unavailable TurnError" do
    srv =
      start_server(
        "s-down",
        BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}),
        {DownStore, nil}
      )

    assert {:error, %TurnError{type: :session_unavailable, reason: :store_down}} =
             Turn.Server.run(srv, %{chat_message: "hi"})
  end

  test "Turn.Session.run/2 wraps a registry failure the same way" do
    defmodule DownRegistry do
      @moduledoc false
      def whereis(_handle, _sid), do: {:error, :registry_down}
    end

    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Turn.Session.run(
               Turn.Session.new(
                 session_id: "s",
                 registry: {DownRegistry, nil},
                 store: {InMemory, InMemory.new()},
                 supervisor: nil,
                 config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})
               ),
               "hi"
             )
  end

  defmodule RaisingProvider do
    @moduledoc false
    def fetch(_handle, _template_id), do: raise(ArgumentError, "provider bug")
  end

  test "a session whose server raises in init replies :session_unavailable with no stacktrace" do
    store = InMemory.new()
    sid = "s-init-raise-#{System.unique_integer([:positive])}"
    tmpl = ConfigTemplate.from_config(TurnConfig.build(), "kind")
    :ok = InMemory.save_config_template(store, sid, tmpl)
    {:ok, sup} = Turn.Supervisor.start_link([])

    session =
      Turn.Session.new(
        session_id: sid,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        supervisor: sup,
        template_provider: {RaisingProvider, nil}
      )

    assert {:error, %TurnError{type: :session_unavailable, reason: reason} = error} =
             Turn.Session.run(session, "hi")

    assert %ArgumentError{message: "provider bug"} = reason
    refute contains_stacktrace?(error)
  end

  test "a bad server option raises in the caller of Session.run/2 (Ruling 7)" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    session =
      Turn.Session.new(
        session_id: "s-bad-opt-#{System.unique_integer([:positive])}",
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: sup,
        config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})
      )

    # Bypasses new/1's check on purpose: start_server/2 checks it again in the caller.
    session = %{session | server_options: [on_approval_timeout: :sometimes]}

    assert_raise ArgumentError,
                 ~r/^Normandy\.Agents\.Turn\.Supervisor\.start_server\/2: invalid value for :on_approval_timeout/,
                 fn -> Turn.Session.run(session, "hi") end
  end

  test "a server whose start_link raises replies :session_unavailable with no stacktrace" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    session =
      Turn.Session.new(
        session_id: "s-bad-opt-#{System.unique_integer([:positive])}",
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: sup,
        supervisor_mod: UncheckedSupervisor,
        config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})
      )

    session = %{session | server_options: [on_approval_timeout: :sometimes]}

    assert {:error, %TurnError{type: :session_unavailable, reason: reason} = error} =
             Turn.Session.run(session, "hi")

    assert %ArgumentError{} = reason
    refute contains_stacktrace?(error)
  end

  test "a rejected input replies the bare ValidationError" do
    srv =
      start_server(
        "s-reject",
        BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"}),
        {InMemory, InMemory.new()}
      )

    assert {:error, %Normandy.Schema.ValidationError{}} =
             Turn.Server.run(srv, %{chat_mesage: "typo"})
  end

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
