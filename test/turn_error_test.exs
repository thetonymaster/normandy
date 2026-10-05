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

  @stacktrace [{M, :f, 1, [file: ~c"m.ex", line: 1]}, {M, :g, [:arg], []}]

  test "task_down drops the stacktrace of a throw, an erlang error and a nested exit" do
    # A worker that throws exits with {{:nocatch, value}, stacktrace}.
    assert %TurnError{type: :task_down, reason: {:nocatch, :boom}} =
             TurnError.task_down({{:nocatch, :boom}, @stacktrace})

    assert %TurnError{type: :task_down, reason: :badarith} =
             TurnError.task_down({:badarith, @stacktrace})

    e = %RuntimeError{message: "x"}

    # A GenServer.call to a process that raised exits with {{e, stacktrace}, {mod, fun, args}}.
    assert %TurnError{type: :task_down, reason: {^e, {GenServer, :call, [:pid, :msg, 5000]}}} =
             TurnError.task_down({{e, @stacktrace}, {GenServer, :call, [:pid, :msg, 5000]}})

    # BaseAgent's caught exit or throw: {kind, reason}.
    assert %TurnError{type: :task_down, reason: {:throw, {:nocatch, :boom}}} =
             TurnError.task_down({:throw, {{:nocatch, :boom}, @stacktrace}})

    # Not a stacktrace: kept as is.
    assert %TurnError{type: :task_down, reason: {:shutdown, [1, 2]}} =
             TurnError.task_down({:shutdown, [1, 2]})
  end

  describe "from_reason/1" do
    test "rejections and halts return the exception bare" do
      v = %Normandy.Schema.ValidationError{message: "m", errors: []}
      g = %Normandy.Guardrails.ViolationError{message: "m", violations: []}
      p = %Normandy.HookHaltError{event: :on_prompt, hook: M, reason: "r"}
      h = %Normandy.HookHaltError{event: :before_llm, hook: M, reason: "r"}

      assert TurnError.from_reason({:rejected, v}) == v
      assert TurnError.from_reason({:rejected, g}) == g
      assert TurnError.from_reason({:rejected, p}) == p
      assert TurnError.from_reason({:hook_halted, h}) == h
    end

    test "a task_down carrying a domain exception returns it bare, its stacktrace dropped" do
      e = Normandy.LLMError.new(type: :rate_limit, retryable?: true)
      assert TurnError.from_reason({:task_down, {e, @stacktrace}}) == e
    end

    test "a task_down carrying any other exception or an exit reason is a :task_down TurnError" do
      e = %RuntimeError{message: "x"}

      assert %TurnError{type: :task_down, reason: ^e} =
               TurnError.from_reason({:task_down, {e, @stacktrace}})

      assert %TurnError{type: :task_down, reason: :killed} =
               TurnError.from_reason({:task_down, :killed})

      assert %TurnError{type: :task_down, reason: {:nocatch, :boom}} =
               TurnError.from_reason({:task_down, {{:nocatch, :boom}, @stacktrace}})
    end

    test "shell failures are TurnErrors of their type" do
      e = %RuntimeError{message: "x"}

      assert %TurnError{type: :handler_crashed, handler: :append, reason: ^e} =
               TurnError.from_reason({:handler_crashed, :append, e})

      assert %TurnError{type: :persist_failed, reason: :disk_full} =
               TurnError.from_reason({:persist_failed, :disk_full})

      assert %TurnError{type: :approval_timeout, reason: ["c1"]} =
               TurnError.from_reason({:approval_timeout, ["c1"]})

      unexpected = {:unexpected_event, :idle, :start}

      assert %TurnError{type: :unexpected_event, reason: ^unexpected} =
               TurnError.from_reason(unexpected)

      assert %TurnError{type: :unresumable_state, reason: :running} =
               TurnError.from_reason({:unresumable_state, :running})
    end

    test "an exception is returned bare when it is Normandy's, else wrapped as :task_down" do
      e = Normandy.LLMError.new(type: :overloaded, retryable?: true)
      assert TurnError.from_reason(e) == e

      t = %TurnError{type: :task_down, reason: :killed}
      assert TurnError.from_reason(t) == t

      bug = %RuntimeError{message: "x"}
      assert %TurnError{type: :task_down, reason: ^bug} = TurnError.from_reason(bug)
    end

    test "an unknown reason raises naming it" do
      assert_raise ArgumentError, ~r/no exception for turn failure :what/, fn ->
        TurnError.from_reason(:what)
      end
    end
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

  describe "redact/1" do
    @key_error %KeyError{key: :k, term: %{api_key: "SECRET"}}

    test "a non-domain exception becomes a :task_down TurnError naming only its module" do
      assert TurnError.redact(@key_error) ==
               %TurnError{type: :task_down, reason: %{exception: KeyError}}
    end

    test "a TurnError keeps its type and handler; a non-domain reason is reduced" do
      e = %TurnError{type: :handler_crashed, handler: :append, reason: @key_error}

      assert TurnError.redact(e) ==
               %TurnError{
                 type: :handler_crashed,
                 handler: :append,
                 reason: %{exception: KeyError}
               }
    end

    test "a TurnError nested in a TurnError is redacted too" do
      e = %TurnError{type: :session_unavailable, reason: TurnError.task_down(@key_error)}

      assert %TurnError{reason: %TurnError{type: :task_down, reason: %{exception: KeyError}}} =
               TurnError.redact(e)
    end

    test "domain exceptions, domain reasons and other terms are unchanged" do
      llm = Normandy.LLMError.new(type: :rate_limit, retryable?: true)
      assert TurnError.redact(llm) == llm

      crashed = %TurnError{type: :handler_crashed, handler: :guard, reason: llm}
      assert TurnError.redact(crashed) == crashed

      timeout = %TurnError{type: :approval_timeout, reason: ["c1"]}
      assert TurnError.redact(timeout) == timeout

      assert TurnError.redact({:shutdown, :normal}) == {:shutdown, :normal}
    end

    test "a non-domain exception nested in tuples and lists is reduced at any depth" do
      llm = Normandy.LLMError.new(type: :rate_limit, retryable?: true)
      reason = {@key_error, {GenServer, :call, [:pid, [@key_error, llm], 5000]}}

      assert TurnError.redact(%TurnError{type: :task_down, reason: reason}).reason ==
               {%{exception: KeyError},
                {GenServer, :call, [:pid, [%{exception: KeyError}, llm], 5000]}}

      assert TurnError.redact({:shutdown, [@key_error]}) == {:shutdown, [%{exception: KeyError}]}
    end

    test "is idempotent" do
      once = TurnError.redact(@key_error)
      assert TurnError.redact(once) == once
    end
  end
end
