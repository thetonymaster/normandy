defmodule Normandy.Agents.BaseAgentGuardrailLogTest do
  @moduledoc """
  Final review I2 (Q's decision, 2026-10-07): an `on_violation: :warn` output guardrail
  logs the guard, the path and the count, never the violation messages, which quote the
  guard's configuration (a forbidden term, a regex pattern). The messages stay in the
  `ViolationError` a `:block` agent returns.

  `BaseAgent.run/3` logs in the caller's process, so `Normandy.Test.OwnLog` keeps this
  module async.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.{ForbiddenSubstrings, RegexGuard}
  alias Normandy.Guardrails.ViolationError
  alias Normandy.Test.OwnLog
  alias Normandy.Test.StubClient

  @term "tok-INTERNAL-7731"
  @pattern ~r/acct-\d{6}/
  @answer "the token tok-INTERNAL-7731 for acct-123456"

  defp agent(guard, on_violation) do
    BaseAgent.init(%{
      client: %StubClient{reply: fn rm -> %{rm | chat_message: @answer} end},
      model: "m",
      guardrails: [output: [guard], on_violation: on_violation]
    })
  end

  test ":warn logs the guard, path and count, never a forbidden term" do
    guard = {ForbiddenSubstrings, terms: [@term], field: :chat_message}

    log =
      OwnLog.capture(fn ->
        assert {:ok, _config, %{chat_message: @answer}} =
                 BaseAgent.run(agent(guard, :warn), "hi")
      end)

    assert log =~
             "[warning] Agent output guardrail violation: ForbiddenSubstrings at chat_message " <>
               "(1 violation)"

    refute log =~ @term
  end

  test ":warn never logs a regex pattern" do
    guard = {RegexGuard, patterns: [@pattern], field: :chat_message}

    log = OwnLog.capture(fn -> assert {:ok, _, _} = BaseAgent.run(agent(guard, :warn), "hi") end)

    assert log =~ "Agent output guardrail violation: RegexGuard at chat_message (1 violation)"
    refute log =~ Regex.source(@pattern)
    refute log =~ "acct-"
  end

  test ":block keeps the full messages in the ViolationError" do
    guard = {ForbiddenSubstrings, terms: [@term], field: :chat_message}

    assert {:error, %ViolationError{violations: [violation]}} =
             BaseAgent.run(agent(guard, :block), "hi")

    assert violation.message =~ @term
  end
end
