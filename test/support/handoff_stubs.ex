defmodule Normandy.Test.HandoffStubs do
  @moduledoc false
  # Functions a peer node can call: test modules aren't on a peer's code path,
  # but test/support is compiled into the app, so captures of these work there.

  alias Normandy.Test.TurnConfig

  def client(_token), do: TurnConfig.build().client

  def call_llm(_config, _state, _request),
    do: %TurnConfig.Resp{content: "resumed-done", tool_calls: nil}
end
