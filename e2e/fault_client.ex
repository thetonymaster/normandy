# e2e/fault_client.ex — a Model client that fails chosen converse calls with a 529 and passes
# the rest to a real ClaudioAdapter. Loaded with Code.require_file (protocols are not
# consolidated under MIX_ENV=test, so this defimpl takes effect at runtime).
defmodule E2E.FaultClient do
  @moduledoc false
  defstruct [:inner, :counter, faults: MapSet.new()]

  def new(%Normandy.LLM.ClaudioAdapter{} = inner, fault_indices) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %__MODULE__{inner: inner, counter: counter, faults: MapSet.new(fault_indices)}
  end

  def converse_calls(%__MODULE__{counter: c}), do: Agent.get(c, & &1)
end

defimpl Normandy.Agents.Model, for: E2E.FaultClient do
  alias Normandy.Agents.Model

  def completitions(c, model, temperature, max_tokens, messages, response_model),
    do: Model.completitions(c.inner, model, temperature, max_tokens, messages, response_model)

  def converse(c, model, temperature, max_tokens, messages, response_model, opts) do
    index = Agent.get_and_update(c.counter, &{&1 + 1, &1 + 1})

    if MapSet.member?(c.faults, index) do
      IO.puts("  [fault] converse call #{index}: injected 529 overloaded")
      {:error, Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true, detail: "injected by E2E.FaultClient")}
    else
      Model.converse(c.inner, model, temperature, max_tokens, messages, response_model, opts)
    end
  end
end
