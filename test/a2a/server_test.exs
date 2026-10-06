defmodule Normandy.A2A.ServerTest do
  use ExUnit.Case, async: true

  # A function clause that fails on any argument but :ok.
  defmodule Picky do
    @moduledoc false
    def only_ok(:ok), do: :ok
  end

  alias Normandy.Agents.BaseAgent
  alias Normandy.Tools.Toolset

  defmodule Verdict do
    use Normandy.Schema

    io_schema "a verdict" do
      field(:verdict, :string, description: "verdict")
    end
  end

  alias Normandy.A2A.Server
  alias Normandy.MCP.ToolWrapper

  describe "build_agent_card/2" do
    test "creates agent card with required fields" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Test Agent",
          description: "A test agent"
        )

      assert card.name == "Test Agent"
      assert card.description == "A test agent"
    end

    test "includes version" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          version: "1.0.0"
        )

      assert card.version == "1.0.0"
    end

    test "includes provider" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          provider_url: "https://example.com",
          provider_org: "My Org"
        )

      assert card.provider.url == "https://example.com"
      assert card.provider.organization == "My Org"
    end

    test "includes interface from url" do
      config = build_minimal_config()

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          url: "https://myapp.com/a2a"
        )

      assert length(card.supported_interfaces) == 1
      [iface] = card.supported_interfaces
      assert iface.url == "https://myapp.com/a2a"
      assert iface.protocol_binding == "jsonrpc+http"
    end

    test "adds skills from tool registry" do
      tool = %Claudio.MCP.Client.Tool{
        name: "search",
        description: "Search the web",
        input_schema: %{}
      }

      wrapper = ToolWrapper.new(MockMCPAdapter, :client, tool, prefix: false)
      registry = Toolset.new([wrapper])
      config = %{build_minimal_config() | toolset: registry}

      card =
        Server.build_agent_card(config,
          name: "Agent",
          description: "Desc",
          expose_tools: ["search"]
        )

      assert length(card.skills) == 1
      [skill] = card.skills
      assert skill.id == "search"
      assert skill.description == "Search the web"
    end

    test "lists no tools unless :expose_tools names them" do
      config = %{build_minimal_config() | toolset: two_tool_registry()}

      assert Server.build_agent_card(config, name: "A", description: "D").skills == []

      assert ["lookup"] =
               Server.build_agent_card(config,
                 name: "A",
                 description: "D",
                 expose_tools: ["lookup"]
               ).skills
               |> Enum.map(& &1.id)

      assert ["lookup", "search"] =
               Server.build_agent_card(config, name: "A", description: "D", expose_tools: :all).skills
               |> Enum.map(& &1.id)
               |> Enum.sort()
    end
  end

  describe "handle_message/2" do
    alias Claudio.A2A.{Message, Part}

    defp agent(client_fields) do
      BaseAgent.init(%{
        client: struct(Normandy.Test.TaggingClient, [name: "agent"] ++ client_fields),
        model: "test-model"
      })
    end

    test "runs the agent on the message text and returns the answer" do
      message = Message.new(:user, [Part.text("hello")])

      assert {:ok, %Claudio.A2A.Task{status: %{state: :completed}, artifacts: [artifact]}} =
               Server.handle_message(agent([]), message)

      assert [%{text: text}] = artifact.parts
      assert text =~ "hello"
    end

    test "an answer without chat_message is sent as its schema's JSON, not inspect output" do
      config =
        BaseAgent.init(%{
          client: %NormandyTest.Support.ModelMockup{},
          model: "test-model",
          output_schema: %Verdict{verdict: "approve"}
        })

      message = Message.new(:user, [Part.text("hello")])

      assert {:ok, %Claudio.A2A.Task{artifacts: [%{parts: [%{text: text}]}]}} =
               Server.handle_message(config, message)

      assert text =~ ~s("verdict")
      refute text =~ "%"
      refute text =~ "__meta__"
    end

    test "a message with no text is refused instead of run as an empty prompt" do
      message = Message.new(:user, [Part.file("https://example.com/a.pdf", "application/pdf")])

      assert {:error, :no_text} = Server.handle_message(agent(fail_on: ""), message)
    end

    test "a failing agent gives the remote a generic error and logs the detail" do
      message = Message.new(:user, [Part.text("hello")])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :agent_failed} = Server.handle_message(agent(fail_on: "hello"), message)
        end)

      assert log =~ "agent failed"
    end

    test "the failure log keeps stacktrace arities, never the arguments" do
      message = Message.new(:user, [Part.text("hello")])

      failing =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{
            reply: fn _ -> picky().only_ok("SECRET-ARG") end
          },
          model: "test-model"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :agent_failed} = Server.handle_message(failing, message)
        end)

      assert log =~ "agent failed"
      assert log =~ "only_ok/1"
      refute log =~ "SECRET-ARG"
    end

    test "an agent that throws gets the same generic error, not a crash" do
      message = Message.new(:user, [Part.text("hello")])

      thrower =
        BaseAgent.init(%{
          client: %Normandy.Test.StubClient{reply: fn _ -> throw(:no_answer) end},
          model: "test-model"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :agent_failed} = Server.handle_message(thrower, message)
        end)

      assert log =~ "agent failed"
    end
  end

  # The module at runtime, so the compiler doesn't flag the clause that can't match.
  defp picky, do: Picky

  defp two_tool_registry do
    tools =
      for {name, desc} <- [{"search", "Search"}, {"lookup", "Look up"}] do
        ToolWrapper.new(
          MockMCPAdapter,
          :client,
          %Claudio.MCP.Client.Tool{
            name: name,
            description: desc,
            input_schema: %{}
          },
          prefix: false
        )
      end

    Toolset.new(tools)
  end

  defmodule MockMCPAdapter do
    @behaviour Claudio.MCP.Client

    @impl true
    def list_tools(_client, _opts), do: {:ok, []}
    @impl true
    def call_tool(_client, _name, _args, _opts), do: {:ok, "result"}
    @impl true
    def list_resources(_client, _opts), do: {:ok, []}
    @impl true
    def read_resource(_client, _uri, _opts), do: {:ok, ""}
    @impl true
    def list_prompts(_client, _opts), do: {:ok, []}
    @impl true
    def get_prompt(_client, _name, _args, _opts), do: {:ok, ""}
    @impl true
    def ping(_client, _opts), do: :ok
  end

  defp build_minimal_config do
    alias Normandy.Components.AgentMemory

    %Normandy.Agents.BaseAgentConfig{
      input_schema: %{},
      output_schema: %{},
      client: %{},
      model: "test-model",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      temperature: 0.7,
      toolset: nil
    }
  end
end
