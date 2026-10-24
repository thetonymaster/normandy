defmodule Normandy.Agents.Turn.DriverHandlersDefaultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn.Driver.Handlers

  test "default/0 is the set Turn.Server uses when :handlers is nil" do
    assert %Handlers{} = default = Handlers.default()

    for key <- [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :compact, :emit] do
      assert is_function(Map.fetch!(default, key)), "#{key} is not a function"
    end

    assert default == Normandy.Agents.BaseAgent.Handlers.non_streaming_handlers()
  end

  test "a custom set is built from default/0" do
    validate = fn _acc, response -> response end
    assert %Handlers{validate: ^validate} = %{Handlers.default() | validate: validate}
  end
end
