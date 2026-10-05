defmodule Normandy.TurnErrorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Normandy.TurnError

  test "domain? is true for Normandy's failure exceptions only" do
    for e <- [
          Normandy.LLMError.new(type: :rate_limit, retryable?: true),
          %Normandy.Schema.ValidationError{message: "m", errors: []},
          %Normandy.Guardrails.ViolationError{message: "m", violations: []},
          %Normandy.HookHaltError{event: :on_prompt, hook: M, reason: "r"},
          %Normandy.ModelCatalogError{model: "m", reason: :timeout},
          %TurnError{type: :persist_failed, reason: :disk_full}
        ],
        do: assert(TurnError.domain?(e), inspect(e.__struct__))

    refute TurnError.domain?(%RuntimeError{message: "bug"})
    refute TurnError.domain?(%FunctionClauseError{})
  end

  test "an unknown type raises naming the known ones" do
    assert_raise ArgumentError, ~r/unknown :type :nope.*:persist_failed/, fn ->
      TurnError.exception(type: :nope)
    end
  end

  test "task_down drops a stacktrace and keeps the exception" do
    e = %RuntimeError{message: "x"}
    assert %TurnError{type: :task_down, reason: ^e} = TurnError.task_down({e, [{M, :f, 1, []}]})
    assert %TurnError{type: :task_down, reason: :killed} = TurnError.task_down(:killed)
  end

  test "messages name the failure, never a config or argument value" do
    secret = %{api_key: "sk-secret"}

    for e <- [
          %TurnError{type: :handler_crashed, handler: :append, reason: %MatchError{term: secret}},
          %TurnError{type: :task_down, reason: {:timeout, {GenServer, :call, [secret]}}},
          %TurnError{type: :session_unavailable, reason: {:no_config_template, "s1"}}
        ] do
      message = Exception.message(e)
      refute message =~ "sk-secret"
      assert message =~ String.replace(Atom.to_string(e.type), "_", " ")
    end
  end

  test "format_stacktrace keeps arities, never arguments" do
    text =
      TurnError.format_stacktrace([
        {M, :f, [%{api_key: "sk-secret"}], [file: ~c"m.ex", line: 1]}
      ])

    assert text =~ "M.f/1"
    refute text =~ "sk-secret"
  end

  test "log_raised logs the module and an arity-only stacktrace, and returns the exception" do
    e = %MatchError{term: %{api_key: "sk-secret"}}
    stacktrace = [{M, :f, [%{api_key: "sk-secret"}], [file: ~c"m.ex", line: 1]}]

    log =
      capture_log(fn ->
        assert {:error, ^e} = TurnError.log_raised("Agent a1", e, stacktrace)
      end)

    assert log =~ "Agent a1 raised MatchError"
    assert log =~ "M.f/1"
    refute log =~ "sk-secret"
  end
end
