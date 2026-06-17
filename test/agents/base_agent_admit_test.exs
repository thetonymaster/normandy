defmodule NormandyTest.BaseAgentAdmitTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.MaxLength

  defp base_config(extra) do
    Map.merge(
      %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "claude-haiku-4-5-20251001",
        temperature: 0.9
      },
      extra
    )
  end

  # Guard implementing check/3 — blocks unless the host context allows it.
  # Proves admit/3 threads context through Guardrails.run/3 to the guard.
  defmodule ContextGate do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(value, opts), do: check(value, opts, %{})

    @impl true
    def check(_value, _opts, %{allow: true}), do: :ok

    def check(_value, _opts, _context) do
      {:error, [%{guard: __MODULE__, path: [], message: "not allowed", constraint: :needs_allow}]}
    end
  end

  # Always crashes — used with on_error: :closed to exercise the :guard_error
  # path and the :error decision outcome.
  defmodule CrashGuard do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts), do: raise("boom")
  end

  # Records any LLM invocation against the test pid carried in the struct, so
  # the assertion is independent of which process runs a turn (gen_statem FSM).
  defmodule SpyClient do
    defstruct [:test_pid]

    defimpl Normandy.Agents.Model do
      def converse(config, _model, _temp, _max, _messages, response_model, _opts \\ []) do
        send(config.test_pid, :llm_called)
        response_model
      end

      def completitions(config, _model, _temp, _max, _messages, response_model) do
        send(config.test_pid, :llm_called)
        response_model
      end
    end
  end

  describe "admit/2" do
    test "returns :ok when no input guardrails are configured" do
      agent = BaseAgent.init(base_config(%{}))
      assert BaseAgent.admit(agent, "anything") == :ok
    end

    test "returns :ok when the input guardrails pass" do
      agent = BaseAgent.init(base_config(%{input_guardrails: [{MaxLength, limit: 100}]}))
      assert BaseAgent.admit(agent, "fine") == :ok
    end

    test "returns {:block, violations} instead of raising when a guard rejects" do
      agent = BaseAgent.init(base_config(%{input_guardrails: [{MaxLength, limit: 5}]}))

      assert {:block, [violation]} = BaseAgent.admit(agent, "too long input")
      assert violation.constraint == :max_length
    end

    test "performs no LLM turn on either the block or the pass path" do
      agent =
        BaseAgent.init(
          base_config(%{
            client: %SpyClient{test_pid: self()},
            input_guardrails: [{MaxLength, limit: 5}]
          })
        )

      assert {:block, _} = BaseAgent.admit(agent, "too long input")
      assert BaseAgent.admit(agent, "ok") == :ok

      refute_received :llm_called
    end
  end

  describe "admit/3" do
    test "threads context to a guard implementing check/3" do
      agent = BaseAgent.init(base_config(%{input_guardrails: [ContextGate]}))

      assert {:block, [violation]} = BaseAgent.admit(agent, "x", %{allow: false})
      assert violation.constraint == :needs_allow

      assert BaseAgent.admit(agent, "x", %{allow: true}) == :ok
    end

    test "defaults context to an empty map (admit/2 == admit/3 with %{})" do
      agent = BaseAgent.init(base_config(%{input_guardrails: [ContextGate]}))

      # No :allow in the empty default context → blocked.
      assert {:block, _} = BaseAgent.admit(agent, "x")
    end
  end

  describe "admit telemetry" do
    setup do
      handler_id = "admit-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:normandy, :agent, :guardrail, :decision],
          [:normandy, :agent, :guardrail, :violation]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits a :decision{outcome: :block} and a :violation event on rejection" do
      agent =
        BaseAgent.init(
          base_config(%{name: "admit-agent", input_guardrails: [{MaxLength, limit: 1}]})
        )

      assert {:block, _} = BaseAgent.admit(agent, "xx")

      assert_receive {:telemetry, [:normandy, :agent, :guardrail, :decision], measurements,
                      decision_meta}

      assert decision_meta.outcome == :block
      assert decision_meta.stage == :input
      assert decision_meta.agent_name == "admit-agent"
      assert decision_meta.guards == [MaxLength]
      assert measurements.count == 1

      assert_receive {:telemetry, [:normandy, :agent, :guardrail, :violation], _m, violation_meta}
      assert violation_meta.stage == :input
    end

    test "emits a :decision{outcome: :admit} on a pass" do
      agent =
        BaseAgent.init(
          base_config(%{name: "admit-agent", input_guardrails: [{MaxLength, limit: 100}]})
        )

      assert BaseAgent.admit(agent, "fine") == :ok

      assert_receive {:telemetry, [:normandy, :agent, :guardrail, :decision], _m, decision_meta}
      assert decision_meta.outcome == :admit

      refute_received {:telemetry, [:normandy, :agent, :guardrail, :violation], _, _}
    end

    test "emits no telemetry when no guardrails are configured" do
      agent = BaseAgent.init(base_config(%{}))

      assert BaseAgent.admit(agent, "anything") == :ok

      refute_received {:telemetry, [:normandy, :agent, :guardrail, :decision], _, _}
    end

    test "emits a :decision{outcome: :error} when a guard crashes under on_error: :closed" do
      agent =
        BaseAgent.init(
          base_config(%{
            name: "admit-agent",
            input_guardrails: [{CrashGuard, on_error: :closed}]
          })
        )

      assert {:block, [violation]} = BaseAgent.admit(agent, "x")
      assert violation.constraint == :guard_error

      assert_receive {:telemetry, [:normandy, :agent, :guardrail, :decision], _m, decision_meta}
      assert decision_meta.outcome == :error
    end
  end
end
