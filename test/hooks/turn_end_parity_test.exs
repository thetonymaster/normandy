defmodule Normandy.Hooks.TurnEndParity.Ask do
  @moduledoc false
  use Normandy.Schema

  io_schema "A question" do
    field(:q, :string, required: true)
  end
end

defmodule Normandy.Hooks.TurnEndParity.Decision do
  @moduledoc false
  use Normandy.Schema

  io_schema "A decision" do
    field(:action, :string, required: true, enum: ["approve", "deny"])
  end
end

defmodule Normandy.Hooks.TurnEndParityTest do
  @moduledoc """
  `on_turn_end` sees the same outcome for a failed turn whichever shell ran it. The two
  shells classify it separately: BaseAgent from the exception the run raised
  (`Hooks.BaseAgentGlue`), `Turn.Server` from the core's fail reason (`Hooks.ServerGlue`)
  or its refusal of the input. Each row runs the same agent through `BaseAgent.run/3` and
  `Turn.Server.run/2` and compares the `{kind, exception}` the hook gets.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Guardrails.Builtins.MaxLength
  alias Normandy.Guardrails.ViolationError
  alias Normandy.HookHaltError
  alias Normandy.Hooks.TurnEndParity.{Ask, Decision}
  alias Normandy.LLMError
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.{FakeClient, FakeTool}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe
  alias Normandy.Tools.Toolset

  @server_error LLMError.new(type: :server, retryable?: false, detail: "boom")

  # {name, expected kind, expected exception module, input, script, init opts, hook returns}
  @rows [
    {"input that breaks the input schema", :rejected, ValidationError, %{}, [],
     %{input_schema: %Ask{}}, []},
    {"an input guardrail block", :rejected, ViolationError, "far too long", [],
     %{guardrails: [input: [{MaxLength, limit: 5}]]}, []},
    {"an on_prompt halt", :rejected, HookHaltError, "hi", [], %{}, [on_prompt: {:halt, "no"}]},
    {"an output guardrail block", :rejected, ViolationError, "hi", [{:text, "a long answer"}],
     %{guardrails: [output: [{MaxLength, limit: 5, field: :chat_message}]]}, []},
    {"a constraint still broken once re-asks are spent", :rejected, ValidationError, "decide",
     [
       {:tool_calls, [{"weather", %{}}]},
       {:text, ~s({"action": "delete"})},
       {:text, ~s({"action": "delete"})}
     ],
     %{
       output_schema: %Decision{},
       toolset: Toolset.new([%FakeTool{}]),
       json_retry_max_attempts: 1
     }, []},
    {"a before_llm halt", :error, HookHaltError, "hi", [], %{}, [before_llm: {:halt, "stop"}]},
    {"an LLMError from the model", :error, LLMError, "hi", [{:error, @server_error}], %{}, []}
  ]

  for {name, kind, module, input, script, opts, returns} <- @rows do
    test "#{name}: both shells report {#{inspect(kind)}, %#{inspect(module)}{}}" do
      row =
        {unquote(Macro.escape(input)), unquote(Macro.escape(script)), unquote(Macro.escape(opts)),
         unquote(returns)}

      assert {unquote(kind), %unquote(module){}} = via_run(row)
      assert {unquote(kind), %unquote(module){}} = via_server(row)
    end
  end

  defp agent({_input, script, opts, returns}) do
    %{
      client: FakeClient.new(script),
      model: "claude-opus-5-5",
      behaviours: %Config{hooks: [{Probe, notify: TestHooks.sink(), tag: :p, returns: returns}]}
    }
    |> Map.merge(opts)
    |> BaseAgent.init()
  end

  defp via_run({input, _, _, _} = row) do
    assert {:error, _exception} = BaseAgent.run(agent(row), input)
    turn_end_outcome()
  end

  defp via_server({input, _, _, _} = row) do
    {:ok, srv} =
      Server.start_link(
        session_id: "parity-#{System.unique_integer([:positive])}",
        config: agent(row),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:error, _exception} = Server.run(srv, input)
    turn_end_outcome()
  end

  defp turn_end_outcome do
    assert_receive {:hook, :p, :on_turn_end, [outcome, _ctx]}, 2_000
    refute_received {:hook, :p, :on_turn_end, _}
    outcome
  end
end
