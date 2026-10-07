defmodule Normandy.A2A.ServerLimitsTest do
  # SEC-9: an A2A caller's text is bounded, and the host can scope tool_context per caller.
  use ExUnit.Case, async: true

  alias Claudio.A2A.{Message, Part}
  alias Normandy.A2A.Server
  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.ToolCall
  alias Normandy.Test.{ContextProbe, FakeClient, OwnLog, StubClient, TelemetryCapture}
  alias Normandy.Tools.Context

  @request_stop [:normandy, :a2a, :request, :stop]

  defp stub_agent do
    BaseAgent.init(%{
      client: %StubClient{notify: self(), reply: fn model -> %{model | chat_message: "ok"} end},
      model: "test-model",
      name: "limits-agent"
    })
  end

  defp text_message(bytes), do: Message.new(:user, [Part.text(String.duplicate("a", bytes))])

  describe ":max_text_bytes" do
    test "100_000 bytes run; 100_001 are :too_large and never reach the model" do
      assert {:ok, %Claudio.A2A.Task{}} =
               Server.handle_message(stub_agent(), text_message(100_000))

      assert_received {:converse, _request, _opts}

      # handle_message/4 logs in the caller; OwnLog keeps another async test's A2A log
      # (ServerTest's failure-log test) out of this refute.
      log =
        OwnLog.capture(fn ->
          assert {:error, :too_large} = Server.handle_message(stub_agent(), text_message(100_001))
        end)

      refute_received {:converse, _request, _opts}
      refute log =~ "A2A Server"
    end

    test "the limit counts every text part" do
      message =
        Message.new(:user, [
          Part.text(String.duplicate("a", 6)),
          Part.text(String.duplicate("b", 5))
        ])

      assert {:error, :too_large} =
               Server.handle_message(stub_agent(), message, [], max_text_bytes: 10)

      assert {:ok, _task} = Server.handle_message(stub_agent(), message, [], max_text_bytes: 11)
    end

    test "a non-binary text from from_map/1 cannot bypass the limit" do
      big = String.duplicate("a", 6)

      message =
        Message.from_map(%{
          "role" => "user",
          "parts" => [%{"text" => [big, big]}]
        })

      assert {:error, :invalid_message} =
               Server.handle_message(stub_agent(), message, [], max_text_bytes: 10)

      refute_received {:converse, _request, _opts}
    end

    test "nil sets no limit" do
      assert {:ok, _task} =
               Server.handle_message(stub_agent(), text_message(100_001), [], max_text_bytes: nil)
    end

    test "the request span's stop says :too_large" do
      ref = TelemetryCapture.attach([@request_stop], agent_name: "limits-agent")

      Server.handle_message(stub_agent(), text_message(11), [], max_text_bytes: 10)

      assert_receive {:telemetry, ^ref, _measurements, %{status: :error, error_type: :too_large}}
    end
  end

  describe ":tool_context" do
    defp probe_agent do
      %{
        # Three turns (one per handle_message/4 call), each a tool round then an answer.
        client:
          FakeClient.new(
            List.duplicate(
              [
                {:tool_calls, [%ToolCall{id: "call_1", name: "probe", input: %{}}]},
                {:text, "done"}
              ],
              3
            )
            |> List.flatten()
          ),
        model: "test",
        name: "ctx-agent",
        tool_context: %{memory_namespace: "shared"}
      }
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ContextProbe{notify: self()})
    end

    test "each call runs with the tool_context it was given, not the config's" do
      config = probe_agent()
      message = Message.new(:user, [Part.text("go")])

      assert {:ok, _} =
               Server.handle_message(config, message, [],
                 tool_context: %{memory_namespace: "a2a/alice"}
               )

      assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "a2a/alice"}}}

      assert {:ok, _} = Server.handle_message(config, message, [], tool_context: %{tenant: "bob"})
      assert_receive {:probe_ctx, %Context{values: values}}
      assert values == %{tenant: "bob"}

      assert {:ok, _} = Server.handle_message(config, message)
      assert_receive {:probe_ctx, %Context{values: %{memory_namespace: "shared"}}}
    end
  end

  describe "options" do
    test "an unknown option raises, naming it" do
      error =
        assert_raise ArgumentError, fn ->
          Server.handle_message(stub_agent(), text_message(1), [], max_bytes: 10)
        end

      assert error.message =~ "Normandy.A2A.Server.handle_message/4: unknown option :max_bytes"
    end

    test ":tool_context must be a plain map" do
      assert_raise ArgumentError,
                   ~r/handle_message\/4: invalid value for :tool_context option/,
                   fn ->
                     Server.handle_message(stub_agent(), text_message(1), [],
                       tool_context: [tenant: "x"]
                     )
                   end
    end
  end
end
