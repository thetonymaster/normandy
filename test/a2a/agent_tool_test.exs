defmodule Normandy.A2A.AgentToolTest do
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Claudio.A2A.Part
  alias Normandy.A2A.AgentTool
  alias Normandy.Tool
  alias Normandy.Tools.Toolset

  setup do
    card = AgentCard.new("Research Agent", "Helps find information")

    card_with_skills =
      card
      |> AgentCard.add_skill("web_search", "Search the web", tags: ["search"])
      |> AgentCard.add_skill("summarize", "Summarize text", tags: ["nlp"])

    tool = AgentTool.new("https://agent.example.com/a2a", card, prefix: "a2a")

    {:ok, card: card, card_with_skills: card_with_skills, tool: tool}
  end

  describe "new/3" do
    test "creates tool with defaults", %{tool: tool} do
      assert tool.endpoint == "https://agent.example.com/a2a"
      assert tool.agent_card.name == "Research Agent"
      assert tool.skill_id == nil
      assert tool.auth_token == nil
      refute Map.has_key?(tool, :timeout)
      refute Map.has_key?(tool, :input)
    end

    test "creates tool with options", %{card: card} do
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          prefix: "a2a",
          skill_id: "web_search",
          auth_token: "my-token"
        )

      assert tool.skill_id == "web_search"
      assert tool.auth_token == "my-token"
    end

    test ":timeout is a registration option now", %{card: card} do
      error =
        assert_raise ArgumentError, fn ->
          AgentTool.new("https://agent.example.com/a2a", card, prefix: "a2a", timeout: 30_000)
        end

      assert error.message ==
               "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
                 "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end
  end

  describe "sanitize_name/1" do
    test "lowercases and replaces special chars" do
      assert AgentTool.sanitize_name("My Agent!") == "my_agent"
      assert AgentTool.sanitize_name("Research-Agent v2") == "research_agent_v2"
      assert AgentTool.sanitize_name("  spaces  ") == "spaces"
    end
  end

  describe "Normandy.Tool callbacks" do
    test "tool_name without skill", %{tool: tool} do
      assert Tool.name(tool) == "a2a__research_agent"
    end

    test "tool_name with skill", %{card: card} do
      tool = AgentTool.new("https://example.com/a2a", card, prefix: "a2a", skill_id: "web_search")
      assert Tool.name(tool) == "a2a__research_agent__web_search"
    end

    test "tool_description without skill", %{tool: tool} do
      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent and returns its reply. " <>
                 "It describes itself as: Helps find information"
    end

    test "tool_description with matching skill", %{card_with_skills: card} do
      tool = AgentTool.new("https://example.com/a2a", card, prefix: "a2a", skill_id: "web_search")

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent (skill web_search) and " <>
                 "returns its reply. It describes itself as: Search the web"
    end

    test "tool_description with non-matching skill", %{card: card} do
      tool = AgentTool.new("https://example.com/a2a", card, prefix: "a2a", skill_id: "unknown")

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Research Agent (skill unknown) and " <>
                 "returns its reply. It describes itself as: Helps find information"
    end

    test "the card's text is cut to 1_000 characters" do
      card = AgentCard.new("Chatty", String.duplicate("é", 1_200))
      tool = AgentTool.new("https://example.com/a2a", card, prefix: "a2a")

      assert Tool.description(tool) ==
               "Sends a message to the remote agent Chatty and returns its reply. " <>
                 "It describes itself as: " <> String.duplicate("é", 1_000) <> "..."
    end

    test "input_schema has message field", %{tool: tool} do
      schema = Tool.input_schema(tool)
      assert schema["type"] == "object"
      assert schema["properties"]["message"]["type"] == "string"
      assert schema["required"] == ["message"]

      assert schema["properties"]["message"]["description"] ==
               "Message to send to Research Agent. It cannot see this conversation, " <>
                 "so include every detail it needs."
    end
  end

  describe "tool registry integration" do
    test "can be registered", %{tool: tool} do
      registry = Toolset.new([tool])
      assert {:ok, ^tool} = Toolset.fetch(registry, "a2a__research_agent")
    end
  end

  describe "extract_task_result/1" do
    test "extracts text from completed task with artifacts" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{state: :completed},
        artifacts: [
          %Claudio.A2A.Artifact{
            artifact_id: "a1",
            parts: [Part.text("Hello world")]
          }
        ]
      }

      assert {:ok, "Hello world"} = AgentTool.extract_task_result(task)
    end

    test "extracts text from completed task without artifacts but with status message" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{
          state: :completed,
          message: %{parts: [Part.text("Done!")]}
        },
        artifacts: []
      }

      assert {:ok, "Done!"} = AgentTool.extract_task_result(task)
    end

    test "returns fallback for completed task with no content" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{state: :completed},
        artifacts: []
      }

      assert {:ok, "Task completed"} = AgentTool.extract_task_result(task)
    end

    test "returns error for failed task" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{
          state: :failed,
          message: %{parts: [Part.text("Something broke")]}
        }
      }

      assert {:error, "Something broke"} = AgentTool.extract_task_result(task)
    end

    test "returns error for rejected task without message parts" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{state: :rejected, message: nil}
      }

      assert {:error, "Task rejected"} = AgentTool.extract_task_result(task)
    end

    test "returns error for unexpected state" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{state: :canceled}
      }

      assert {:error, msg} = AgentTool.extract_task_result(task)
      assert msg =~ "unexpected state"
    end

    test "handles parts without text field safely" do
      task = %Claudio.A2A.Task{
        id: "task-1",
        status: %{state: :completed},
        artifacts: [
          %Claudio.A2A.Artifact{
            artifact_id: "a1",
            parts: [Part.data("binary-data")]
          }
        ]
      }

      assert {:ok, _text} = AgentTool.extract_task_result(task)
    end
  end

  describe "poll_for_result/4" do
    test "returns timeout error when deadline passed" do
      # Deadline in the past
      deadline = System.monotonic_time(:millisecond) - 1000

      result = AgentTool.poll_for_result("https://example.com/a2a", "task-1", [], deadline)
      assert {:error, msg} = result
      assert msg =~ "timed out"
    end
  end

  describe "Inspect protocol" do
    test "does not leak auth_token in inspect output", %{card: card} do
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          prefix: "a2a",
          auth_token: "bearer-secret-leak-canary"
        )

      output = inspect(tool)

      refute output =~ "bearer-secret-leak-canary"
      refute output =~ "auth_token"
    end

    test "still allows direct auth_token access after redaction", %{card: card} do
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          prefix: "a2a",
          auth_token: "bearer-x"
        )

      assert tool.auth_token == "bearer-x"
      assert Map.get(tool, :auth_token) == "bearer-x"
    end
  end
end
