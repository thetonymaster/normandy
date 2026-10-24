defmodule Normandy.Agents.GuardrailRedactionTest do
  @moduledoc """
  Q's decision on final review I2 (2026-10-07, "reduce everywhere"): a guardrail
  violation's message, which quotes a forbidden term, a regex pattern or model text,
  never leaves the caller's reply. Telemetry, a run's `:exception` metadata and a
  `Turn.Server` turn state's persisted `error` carry `%{guard:, path:, constraint:}` only;
  the `ViolationError` the caller gets keeps every message.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Guardrails.Builtins.{ForbiddenSubstrings, RegexGuard}
  alias Normandy.Guardrails.ViolationError
  alias Normandy.Test.{StubClient, TelemetryCapture}

  @moduletag :capture_log

  @term "tok-INTERNAL-7731"
  @pattern ~r/acct-\d{6}/
  @answer "the token tok-INTERNAL-7731 for acct-123456"

  @violation [:normandy, :agent, :guardrail, :violation]
  @decision [:normandy, :agent, :guardrail, :decision]
  @run_exception [:normandy, :agent, :run, :exception]

  defp name, do: "redact-#{System.unique_integer([:positive])}"

  defp agent(name, guardrails) do
    BaseAgent.init(%{
      client: %StubClient{reply: fn rm -> %{rm | chat_message: @answer} end},
      model: "m",
      name: name,
      guardrails: guardrails
    })
  end

  defp leaks?(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    text =~ @term or text =~ Regex.source(@pattern) or text =~ "acct-"
  end

  test "an input violation's :violation and :decision events carry no term" do
    name = name()
    ref = TelemetryCapture.attach([@violation, @decision], agent_name: name)
    agent = agent(name, input: [{ForbiddenSubstrings, terms: [@term]}])

    assert {:error, %ViolationError{violations: [violation]}} = BaseAgent.run(agent, @answer)
    assert violation.message =~ @term

    assert_received {:telemetry, ^ref, %{count: 1}, %{stage: :input, outcome: :block} = decision}
    assert_received {:telemetry, ^ref, %{count: 1}, %{stage: :input} = event}

    for meta <- [decision, event] do
      refute leaks?(meta)

      assert [%{guard: ForbiddenSubstrings, path: [], constraint: :forbidden_substring} = v] =
               meta.violations

      assert map_size(v) == 3
    end
  end

  test "an output violation's event and the run :exception carry no term or pattern" do
    name = name()
    ref = TelemetryCapture.attach([@violation, @run_exception], agent_name: name)

    agent =
      agent(name,
        output: [
          {ForbiddenSubstrings, terms: [@term], field: :chat_message},
          {RegexGuard, patterns: [@pattern], field: :chat_message}
        ]
      )

    assert {:error, %ViolationError{} = error} = BaseAgent.run(agent, "hi")
    assert Enum.any?(error.violations, &(&1.message =~ @term))

    assert_received {:telemetry, ^ref, _m, %{stage: :output} = event}
    refute leaks?(event)

    assert_received {:telemetry, ^ref, _m, %{reason: %ViolationError{} = reason} = exception}
    refute leaks?(exception)
    assert reason.message == "Agent output guardrail violation"
    assert [%{guard: ForbiddenSubstrings, constraint: :forbidden_substring}] = reason.violations
  end

  test "a regex violation's event carries no pattern" do
    name = name()
    ref = TelemetryCapture.attach([@violation], agent_name: name)
    agent = agent(name, output: [{RegexGuard, patterns: [@pattern], field: :chat_message}])

    assert {:error, %ViolationError{violations: [violation]}} = BaseAgent.run(agent, "hi")
    assert violation.message =~ Regex.source(@pattern)

    assert_received {:telemetry, ^ref, _m, event}
    refute leaks?(event)
  end

  test "Turn.Server persists a blocked turn's error without the term; the reply keeps it" do
    name = name()
    ref = TelemetryCapture.attach([@run_exception], agent_name: name)
    store = InMemory.new()
    sid = "redact-#{System.unique_integer([:positive])}"
    config = agent(name, output: [{ForbiddenSubstrings, terms: [@term], field: :chat_message}])

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        subscriber: nil
      )

    assert {:error, %ViolationError{violations: [violation]}} = Turn.Server.run(srv, "hi")
    assert violation.message =~ @term

    assert {:ok, %Turn.State{status: :failed, error: %ViolationError{} = stored}} =
             InMemory.load_turn_state(store, sid)

    refute leaks?(stored)
    assert [%{guard: ForbiddenSubstrings, constraint: :forbidden_substring}] = stored.violations

    assert_received {:telemetry, ^ref, _m, exception}
    refute leaks?(exception)
  end

  test "ViolationError.redact/1 keeps only Normandy's fixed message and is idempotent" do
    error = %ViolationError{
      message: "custom #{@term}",
      violations: [%{guard: X, path: [:a], message: @term, constraint: :c, term: @term}]
    }

    redacted = ViolationError.redact(error)
    assert redacted.message == "Guardrail violation"
    assert redacted.violations == [%{guard: X, path: [:a], constraint: :c}]
    assert ViolationError.redact(redacted) == redacted
  end
end
