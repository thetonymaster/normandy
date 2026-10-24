defmodule Normandy.Agents.ToolLoopReaskTest do
  @moduledoc """
  AX-18: a tool-using turn's final answer that breaks a constraint the API does not
  enforce is re-asked with the validation errors, `json_retry_max_attempts` times at
  most, with `tool_choice: :none`. The rejected answer and the feedback go only in the
  re-ask request; memory keeps the answer that passed. `stream/3` does not re-ask.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ToolCallResponse, Turn}
  alias Normandy.Agents.Turn.{Inline, Server}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.{FakeClient, FakeTool}
  alias Normandy.Tools.Toolset

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true, enum: ["approve", "deny"])
    end
  end

  @bad ~s({"action": "delete_everything"})
  @good ~s({"action": "approve"})

  defp agent(script, opts \\ []) do
    BaseAgent.init(
      Map.merge(
        %{
          client: FakeClient.new(script),
          model: "claude-opus-5-5",
          output_schema: %Decision{},
          toolset: Toolset.new([%FakeTool{}])
        },
        Map.new(opts)
      )
    )
  end

  defp requests(config), do: FakeClient.requests(config.client)

  test "run/3 re-asks a final answer that breaks a constraint, answer only" do
    config = agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}, {:text, @good}])

    assert {:ok, config, %Decision{action: "approve"}} = BaseAgent.run(config, "decide")

    assert [_loop, _answer, reask] = requests(config)
    assert reask.tool_choice == :none
    assert %{role: "user", content: feedback} = List.last(reask.messages)
    assert feedback =~ "breaks the schema's constraints"
    assert feedback =~ "delete_everything"

    # Memory keeps the answer that passed, not the rejected one or the feedback.
    history = inspect(AgentMemory.messages(config.memory))
    refute history =~ "delete_everything"
    refute history =~ "breaks the schema's constraints"
  end

  test "after json_retry_max_attempts re-asks the turn fails with the ValidationError" do
    config =
      agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}, {:text, @bad}],
        json_retry_max_attempts: 1
      )

    assert {:error, %ValidationError{}} = BaseAgent.run(config, "decide")
    assert FakeClient.remaining(config.client) == 0
  end

  test "enable_json_retry: false fails on the first rejected answer" do
    config =
      agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}], enable_json_retry: false)

    assert {:error, %ValidationError{}} = BaseAgent.run(config, "decide")
    assert FakeClient.remaining(config.client) == 0
  end

  test "stream/3 does not re-ask: the rejected answer already streamed" do
    config = agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}, {:text, @good}])

    assert {:error, %ValidationError{}} = BaseAgent.stream(config, "decide", fn _ -> :ok end)
    assert FakeClient.remaining(config.client) == 1
  end

  test "Turn.Server re-asks and stores only the answer that passed" do
    config = agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}, {:text, @good}])
    store = InMemory.new()

    {:ok, srv} =
      Server.start_link(
        session_id: "s-reask",
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    assert {:ok, %Decision{action: "approve"}} = Server.run(srv, "decide")
    assert FakeClient.remaining(config.client) == 0

    {:ok, entries} = InMemory.history(store, "s-reask")
    stored = inspect(Enum.map(entries, & &1.content))
    refute stored =~ "delete_everything"
    refute stored =~ "breaks the schema's constraints"

    assert [%ToolCallResponse{tool_calls: [_]} | _] =
             for(%{content: %ToolCallResponse{} = r} <- entries, do: r)
  end

  describe "the core" do
    # A turn whose loop answered and is in :finalizing with `resp` as its answer.
    defp finalizing(reasks) do
      s = Turn.new(max_constraint_reasks: reasks, response_model: %ToolCallResponse{})
      %{s | status: :finalizing, last_response: %ToolCallResponse{content: @bad}}
    end

    @error %ValidationError{message: "bad", errors: []}

    test "a rejected answer with re-asks left is asked again, answer only" do
      {s, [{:call_llm, request}]} = Turn.step(finalizing(1), {:output_invalid, @error})

      assert %{final: true, reask: %{response: %ToolCallResponse{content: @bad}, error: @error}} =
               request

      assert %{status: :assistant_streaming, reasking: true, reasks_left: 0} = s

      # Its answer is finalized like the one it replaces, tool calls and all left alone.
      resp = %ToolCallResponse{content: @good, tool_calls: []}

      assert {%{status: :finalizing, reasking: false}, [_finish]} =
               Turn.step(s, {:llm_response, resp})
    end

    test "without re-asks left the turn fails with {:rejected, error}" do
      assert {%{status: :failed, error: {:rejected, @error}}, [{:fail, {:rejected, @error}}]} =
               Turn.step(finalizing(0), {:output_invalid, @error})
    end

    test "a turn state persisted before re-asks existed fails as before" do
      # A struct missing fields on purpose: opaque/1 keeps the type checker out of it.
      old =
        finalizing(1)
        |> Map.delete(:reasks_left)
        |> Map.delete(:reasking)
        |> Normandy.Test.opaque()

      assert {_, [{:fail, {:rejected, @error}}]} = Turn.step(old, {:output_invalid, @error})
    end
  end

  describe "Turn.Inline" do
    # Each call answers; validate rejects "bad" and passes anything else.
    defp inline_deps(answers) do
      {:ok, script} = Agent.start_link(fn -> answers end)
      test_pid = self()

      %{
        call_llm: fn request ->
          send(test_pid, {:request, request})
          {:ok, Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)}
        end,
        validate: fn
          %ToolCallResponse{content: "bad"} -> raise ValidationError, message: "bad", errors: []
          value -> value
        end
      }
    end

    defp answer(text), do: %ToolCallResponse{content: text, tool_calls: []}

    test "re-asks a rejected answer while it has re-asks" do
      state = Turn.new(max_constraint_reasks: 1, response_model: %ToolCallResponse{})

      assert {:ok, final} = Inline.run(state, inline_deps([answer("bad"), answer("good")]))
      assert %ToolCallResponse{content: "good"} = final.final_response
      assert_received {:request, %{final: false}}
      assert_received {:request, %{final: true, reask: %{response: %{content: "bad"}}}}
    end

    test "returns {:rejected, error} once re-asks are spent" do
      state = Turn.new(max_constraint_reasks: 0, response_model: %ToolCallResponse{})

      assert {:error, {:rejected, %ValidationError{}}, _state} =
               Inline.run(state, inline_deps([answer("bad")]))
    end
  end

  test "a re-ask call is marked: before_llm sees reask: true, final: true" do
    defmodule RecordLlm do
      use Normandy.Behaviours.Hooks

      def before_llm(info, _ctx, opts) do
        send(Keyword.fetch!(opts, :to), {:before_llm, info})
        :cont
      end
    end

    # Hook opts are plain data (saved in the config template): a registered name, not a pid.
    name = :"tool_loop_reask_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    config =
      agent([{:tool_calls, [{"weather", %{}}]}, {:text, @bad}, {:text, @good}],
        behaviours: %Normandy.Behaviours.Config{hooks: [{RecordLlm, [to: name]}]}
      )

    assert {:ok, _config, %Decision{action: "approve"}} = BaseAgent.run(config, "decide")
    assert_received {:before_llm, %{final: false, reask: false}}
    assert_received {:before_llm, %{final: false, reask: false}}
    assert_received {:before_llm, %{final: true, reask: true}}
  end
end
