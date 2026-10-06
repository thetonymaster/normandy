defmodule Normandy.Options.TurnOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory

  # {misspelled key, {module, function, args}}. The unknown-key check runs first, so the
  # rows omit required keys and the call raises before it starts or sends anything.
  @cases [
    {:approval_timout_ms, {Turn.Server, :start_link, [[approval_timout_ms: 1]]}},
    {:max_restart, {Turn.Supervisor, :start_link, [[max_restart: 1]]}},
    {:idle_timout_ms, {Turn.Supervisor, :start_server, [:no_supervisor, [idle_timout_ms: 1]]}},
    {:max_restart, {Turn.Supervisor.Horde, :start_link, [[max_restart: 1]]}},
    {:idle_timout_ms,
     {Turn.Supervisor.Horde, :start_server, [:no_supervisor, [idle_timout_ms: 1]]}},
    {:supervisor_md, {Turn.ResumeReaper, :start_link, [[supervisor_md: Turn.Supervisor]]}},
    {:max_iteration, {Turn, :new, [[max_iteration: 3]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  describe "a misspelled or missing option raises in the caller (Review Focus #3)" do
    test "Turn.Supervisor.start_server/2 raises instead of returning the supervisor's {:error, _}" do
      sup = start_supervised!(Turn.Supervisor)

      opts = [
        session_id: "s-typo",
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        approval_timout_ms: 1
      ]

      error = assert_raise ArgumentError, fn -> Turn.Supervisor.start_server(sup, opts) end

      assert error.message =~
               ~r/^Normandy\.Agents\.Turn\.Supervisor\.start_server\/2: unknown option :approval_timout_ms; supported: /

      assert %{active: 0} = DynamicSupervisor.count_children(sup)
    end

    test "a :config that is not a BaseAgentConfig is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-config",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            config: %{client: %{api_key: "sk-secret"}}
          )
        end

      assert error.message =~ "Normandy.Agents.Turn.Server.start_link/1: "
      assert error.message =~ ":config"
      refute error.message =~ "sk-secret"
    end

    test "Turn.Server.start_link/1 without :store raises ArgumentError, not a KeyError in init/1" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(session_id: "s-no-store", registry: {Native, Native.new()})
        end

      assert error.message =~
               "Normandy.Agents.Turn.Server.start_link/1: required :store option not found"
    end

    test "a bad :resume_policy names the key and the allowed values" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-policy",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            resume_policy: :sometimes
          )
        end

      assert error.message =~
               "invalid value for :resume_policy option: expected one of [:lazy, :eager], got: :sometimes"
    end

    test "a :handlers that is not a Handlers struct is an ArgumentError, not Protocol.UndefinedError" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-handlers",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            handlers: %URI{}
          )
        end

      assert error.message =~ ":handlers"
    end

    # The reaper forwards :handlers to Turn.Server.start_link/1 on every reap; a value the
    # server rejects would raise there, in the reaper, long after start_link/1 returned.
    test "Turn.ResumeReaper.start_link/1 rejects a :handlers that Turn.Server would reject" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.ResumeReaper.start_link(
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            supervisor: :no_supervisor,
            template_provider: {Normandy.Behaviours.AgentTemplate, :handle},
            handlers: %{call_llm: &Function.identity/1}
          )
        end

      assert error.message =~
               ~r/^Normandy\.Agents\.Turn\.ResumeReaper\.start_link\/1: expected :handlers option/

      assert error.message =~ "expected Normandy.Agents.Turn.Driver.Handlers, got: a map"
    end
  end
end
