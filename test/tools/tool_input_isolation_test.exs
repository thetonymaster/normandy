defmodule Normandy.Tools.ToolInputIsolationTest do
  @moduledoc false
  # Review Focus #2 (SEC-1): model input that names a tool's config fields never reaches
  # the tool struct. The unknown keys come back as an is_error tool result naming them,
  # the turn goes on, and the registration timeout (not the struct's :timeout field)
  # bounds the run. Under BaseAgent.run/2, BaseAgent.stream/3 and Turn.Server.
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Tools.Context

  defmodule LookupTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "Lookup input" do
        field(:query, :string, required: true, description: "the query")
      end
    end

    use Normandy.Tool, name: "lookup", description: "looks a query up", input: Params

    defstruct [:endpoint, :notify, timeout: 5_000]

    @impl Normandy.Tool
    def run(%__MODULE__{} = tool, %Context{input: %Params{query: query}}) do
      send(tool.notify, {:ran, tool, query})
      # "slow" never returns: only the executor's timeout ends it.
      if query == "slow", do: Process.sleep(:infinity)
      {:ok, "#{tool.endpoint}: #{query}"}
    end
  end

  # One tool round: the hostile call and a slow one, then the final answer.
  defmodule ScriptedClient do
    @moduledoc false
    defstruct notify: nil, options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall

      @hostile ~s({"query":"x","endpoint":"evil","timeout":"x"})

      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          if answered?(request) do
            request.response_model
          else
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{id: "hostile", name: "lookup", input: Jason.decode!(@hostile)},
                %ToolCall{id: "slow", name: "lookup", input: %{"query" => "slow"}}
              ]
            }
          end

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(client, request, _opts) do
        send(client.notify, {:request, request})
        events = if answered?(request), do: text_events(), else: tool_events()
        {:ok, Stream.map(events, & &1)}
      end

      defp answered?(request), do: Enum.any?(request.messages, &(&1.role == "tool"))

      defp tool_events do
        [
          %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
          tool_use(0, "hostile", @hostile),
          %{type: "content_block_stop", index: 0},
          tool_use(1, "slow", ~s({"query":"slow"})),
          %{type: "content_block_stop", index: 1},
          %{type: "message_stop"}
        ]
        |> List.flatten()
      end

      defp tool_use(index, id, json) do
        [
          %{
            type: "content_block_start",
            content_block: %{"type" => "tool_use", "id" => id, "name" => "lookup"},
            index: index
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "input_json_delta", "partial_json" => json},
            index: index
          }
        ]
      end

      defp text_events do
        [
          %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
          %{
            type: "content_block_start",
            content_block: %{"type" => "text", "text" => ""},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => "done"},
            index: 0
          },
          %{type: "content_block_stop", index: 0},
          %{type: "message_stop"}
        ]
      end
    end
  end

  defp tool, do: %LookupTool{endpoint: "https://ok.example", notify: self()}

  defp agent do
    BaseAgent.init(%{client: %ScriptedClient{notify: self()}, model: "m"})
    |> BaseAgent.register_tool(tool(), timeout: 50)
  end

  # The second request carries the tool results the model was sent.
  defp assert_isolated do
    assert_received {:request, _first}
    assert_received {:request, second}

    results =
      second.messages
      |> Enum.filter(&(&1.role == "tool"))
      |> Enum.flat_map(& &1.content)
      |> Map.new(&{&1.tool_use_id, &1})

    hostile = Map.fetch!(results, "hostile")
    assert hostile.is_error
    output = Jason.decode!(hostile.content)

    assert output["error"] ==
             ~s(invalid input for lookup: unknown keys "endpoint", "timeout"; ) <>
               ~s(expected only "query"; the tool was not run. ) <>
               "Correct the input and call the tool again."

    assert [%{"constraint" => "unknown_keys"}] = output["validation_errors"]

    slow = Map.fetch!(results, "slow")
    assert slow.is_error
    # A binary error reason reaches the model bare, with is_error (AX-15).
    assert slow.content == "Tool execution timeout after 50ms"

    # The tool ran once, for "slow", with its struct exactly as registered.
    expected = tool()
    assert_received {:ran, ^expected, "slow"}
    refute_received {:ran, _tool, "x"}
  end

  test "BaseAgent.run/2" do
    assert {:ok, _config, _output} = BaseAgent.run(agent(), "go")
    assert_isolated()
  end

  test "BaseAgent.stream/3" do
    assert {:ok, _config, _output} = BaseAgent.stream(agent(), "go", fn _event -> :ok end)
    assert_isolated()
  end

  test "Turn.Server" do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "isolation-#{System.unique_integer([:positive])}",
        config: agent(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, _output} = Turn.Server.run(srv, "go")
    assert_isolated()
  end
end
