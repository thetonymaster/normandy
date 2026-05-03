defmodule Normandy.A2A.AgentToolTest do
  use ExUnit.Case, async: true

  alias Normandy.A2A.AgentTool
  alias Normandy.Tools.BaseTool

  setup do
    card = Claudio.A2A.AgentCard.new("Research Agent", "Helps find information")

    card_with_skills =
      card
      |> Claudio.A2A.AgentCard.add_skill("web_search", "Search the web", tags: ["search"])
      |> Claudio.A2A.AgentCard.add_skill("summarize", "Summarize text", tags: ["nlp"])

    tool = AgentTool.new("https://agent.example.com/a2a", card)

    {:ok, card: card, card_with_skills: card_with_skills, tool: tool}
  end

  describe "new/3" do
    test "creates tool with defaults", %{tool: tool} do
      assert tool.endpoint == "https://agent.example.com/a2a"
      assert tool.agent_card.name == "Research Agent"
      assert tool.skill_id == nil
      assert tool.auth_token == nil
      assert tool.timeout == 60_000
      assert tool.input == %{}
    end

    test "creates tool with options", %{card: card} do
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          skill_id: "web_search",
          auth_token: "my-token",
          timeout: 30_000
        )

      assert tool.skill_id == "web_search"
      assert tool.auth_token == "my-token"
      assert tool.timeout == 30_000
    end
  end

  describe "prepare_input/2" do
    test "stores raw input", %{tool: tool} do
      updated = AgentTool.prepare_input(tool, %{"message" => "Find elixir docs"})
      assert updated.input == %{"message" => "Find elixir docs"}
    end
  end

  describe "sanitize_name/1" do
    test "lowercases and replaces special chars" do
      assert AgentTool.sanitize_name("My Agent!") == "my_agent"
      assert AgentTool.sanitize_name("Research-Agent v2") == "research_agent_v2"
      assert AgentTool.sanitize_name("  spaces  ") == "spaces"
    end
  end

  describe "BaseTool protocol" do
    test "tool_name without skill", %{tool: tool} do
      assert BaseTool.tool_name(tool) == "a2a__research_agent"
    end

    test "tool_name with skill", %{card: card} do
      tool = AgentTool.new("https://example.com/a2a", card, skill_id: "web_search")
      assert BaseTool.tool_name(tool) == "a2a__research_agent__web_search"
    end

    test "tool_description without skill", %{tool: tool} do
      desc = BaseTool.tool_description(tool)
      assert desc == "Remote A2A agent: Helps find information"
    end

    test "tool_description with matching skill", %{card_with_skills: card} do
      tool = AgentTool.new("https://example.com/a2a", card, skill_id: "web_search")
      desc = BaseTool.tool_description(tool)
      assert desc == "Research Agent - Search the web"
    end

    test "tool_description with non-matching skill", %{card: card} do
      tool = AgentTool.new("https://example.com/a2a", card, skill_id: "unknown")
      desc = BaseTool.tool_description(tool)
      assert desc =~ "skill: unknown"
    end

    test "input_schema has message field", %{tool: tool} do
      schema = BaseTool.input_schema(tool)
      assert schema["type"] == "object"
      assert schema["properties"]["message"]["type"] == "string"
      assert schema["required"] == ["message"]
    end
  end

  describe "tool registry integration" do
    test "can be registered", %{tool: tool} do
      registry = Normandy.Tools.Registry.new([tool])
      assert {:ok, ^tool} = Normandy.Tools.Registry.get(registry, "a2a__research_agent")
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
            parts: [Claudio.A2A.Part.text("Hello world")]
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
          message: %{parts: [Claudio.A2A.Part.text("Done!")]}
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
          message: %{parts: [Claudio.A2A.Part.text("Something broke")]}
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
            parts: [Claudio.A2A.Part.data("binary-data")]
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
          auth_token: "bearer-secret-leak-canary"
        )

      output = inspect(tool)

      refute output =~ "bearer-secret-leak-canary"
      refute output =~ "auth_token"
    end

    test "still allows direct auth_token access after redaction", %{card: card} do
      tool = AgentTool.new("https://agent.example.com/a2a", card, auth_token: "bearer-x")

      assert tool.auth_token == "bearer-x"
      assert Map.get(tool, :auth_token) == "bearer-x"
    end
  end
end
