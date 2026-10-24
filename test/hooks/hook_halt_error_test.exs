defmodule Normandy.HookHaltErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.HookHaltError

  test "message names the event, hook and reason" do
    e = %HookHaltError{event: :on_prompt, hook: MyApp.Redact, reason: "contains SSN"}
    assert Exception.message(e) == "hook MyApp.Redact halted on_prompt: contains SSN"
  end

  test "outcome/1: an on_prompt halt is a rejection, a before_llm halt an error" do
    prompt = %HookHaltError{event: :on_prompt, hook: MyApp.Redact, reason: "r"}
    llm = %HookHaltError{event: :before_llm, hook: MyApp.Budget, reason: "r"}

    assert HookHaltError.outcome(prompt) == {:rejected, prompt}
    assert HookHaltError.outcome(llm) == {:error, llm}
  end
end
