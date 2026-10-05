defmodule Normandy.LogPolicyTest do
  # A Normandy error returned to the caller is not logged (telemetry records it). A bug
  # is logged with its kind, its exception module and an arity-only stacktrace: never
  # its message, a thrown term or an exit reason, which can hold the value it failed on.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess
  alias Normandy.LLMError
  alias Normandy.Resilience.Retry
  alias Normandy.Test.StubClient

  @secret "SECRET-sk-log-me-not"

  defmodule Picky do
    @moduledoc false
    def only_ok(:ok), do: :ok
  end

  defp picky, do: Picky

  defmodule CrashHook do
    @moduledoc false
    use Normandy.Behaviours.Hooks

    @impl true
    def on_prompt(_input, _ctx, _opts), do: raise("bad input SECRET-sk-log-me-not")
  end

  defp agent(reply), do: BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m"})

  defp rate_limited(_rm),
    do: {:error, LLMError.new(type: :rate_limit, retryable?: true, status: 429)}

  defp secret_key_error(_rm), do: Map.fetch!(%{api_key: @secret}, :missing)

  # Every metadata key is printed too: a value hidden in metadata is still logged.
  defp capture_log(fun), do: ExUnit.CaptureLog.capture_log([metadata: :all], fun)

  defp error_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[error]"))

  describe "BaseAgent" do
    test "a returned LLMError is not logged" do
      log =
        capture_log(fn ->
          assert {:error, %LLMError{}} = BaseAgent.run(agent(&rate_limited/1), "hello")
        end)

      assert error_lines(log) == []
    end

    test "a returned ValidationError (rejected input) is not logged" do
      log =
        capture_log(fn ->
          assert {:error, %Normandy.Schema.ValidationError{}} =
                   BaseAgent.run(agent(& &1), %{chat_mesage: "typo"})
        end)

      assert error_lines(log) == []
    end

    test "a stream/3 failure is not logged" do
      log =
        capture_log(fn ->
          assert {:error, %LLMError{}} = BaseAgent.stream(agent(& &1), "hi", fn _ -> :ok end)
        end)

      assert error_lines(log) == []
    end

    # The raise carries a bug to the caller; the boundary that turns it into a value
    # (AgentProcess, Reactive, a workflow step, Turn.Server, A2A) logs it, once.
    test "a bug is raised, not logged" do
      log =
        capture_log(fn ->
          assert_raise KeyError, fn -> BaseAgent.run(agent(&secret_key_error/1), "hello") end
        end)

      assert error_lines(log) == []
      refute log =~ @secret
    end
  end

  describe "AgentProcess (inline)" do
    test "a returned domain error is replied, not logged" do
      {:ok, pid} = AgentProcess.start_link(agent: agent(&rate_limited/1))

      log =
        capture_log(fn -> assert {:error, %LLMError{}} = AgentProcess.run(pid, "hello") end)

      assert error_lines(log) == []
    end

    test "a bug is replied whole and logged once, by module and arity-only frames" do
      {:ok, pid} =
        AgentProcess.start_link(agent: agent(fn _ -> picky().only_ok(@secret) end))

      log =
        capture_log(fn ->
          assert {:error, %FunctionClauseError{}} = AgentProcess.run(pid, "hello")
        end)

      assert [_one] = error_lines(log)
      assert log =~ "FunctionClauseError"
      assert log =~ "only_ok/1"
      refute log =~ @secret
    end
  end

  describe "the shared formatter" do
    test "names the kind and the module, never a message, a thrown term or an exit reason" do
      stacktrace = [{M, :f, [%{api_key: @secret}], [file: ~c"m.ex", line: 1]}]

      for {kind, reason, expected} <- [
            {:error, %KeyError{key: :k, term: %{api_key: @secret}}, "KeyError"},
            {:error, {:badmatch, @secret}, "MatchError"},
            {:error, %RuntimeError{message: @secret}, "RuntimeError"},
            {:throw, {:secret, @secret}, "throw"},
            {:exit, {:timeout, {GenServer, :call, [self(), {:get, @secret}, 5000]}}, "exit"}
          ] do
        text = Normandy.TurnError.format_raised(kind, reason, stacktrace)
        assert text =~ expected
        assert text =~ "M.f/1"
        refute text =~ @secret
      end
    end
  end

  describe "Retry" do
    test "a raised failure is logged by module, never by message or stacktrace arguments" do
      log =
        capture_log(fn ->
          assert {:error, {{:exception, %KeyError{}, _}, 2, _}} =
                   Retry.with_retry(fn -> secret_key_error(nil) end,
                     max_attempts: 2,
                     base_delay: 1,
                     retry_if: fn _ -> true end
                   )
        end)

      assert log =~ "Retry attempt 1/2 failed: KeyError"
      refute log =~ @secret
    end
  end

  describe "A2A server" do
    alias Claudio.A2A.Message
    alias Claudio.A2A.Part
    alias Normandy.A2A.Server

    defp a2a_fail(reply) do
      log =
        capture_log(fn ->
          assert {:error, :agent_failed} =
                   Server.handle_message(agent(reply), Message.new(:user, [Part.text("hi")]))
        end)

      assert log =~ "agent failed"
      refute log =~ @secret
      log
    end

    test "a KeyError, a throw and an exit are logged without their values" do
      assert a2a_fail(&secret_key_error/1) =~ "KeyError"
      assert a2a_fail(fn _ -> throw({:secret, @secret}) end) =~ "throw"
      assert a2a_fail(fn _ -> exit({:secret, @secret}) end) =~ "exit"
    end
  end

  describe "hooks and Turn.Server" do
    test "a crashing hook's RuntimeError message is not logged" do
      config =
        BaseAgent.init(%{
          client: %StubClient{},
          model: "m",
          behaviours: %Normandy.Behaviours.Config{hooks: [{CrashHook, on_error: :open}]}
        })

      log = capture_log(fn -> assert {:ok, _, _} = BaseAgent.run(config, "hello") end)

      assert log =~ "RuntimeError"
      refute log =~ @secret
    end
  end
end
