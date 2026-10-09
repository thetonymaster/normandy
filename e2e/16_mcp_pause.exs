# e2e/16_mcp_pause.exs — Part A: a turn paused on the MCP connector (pause_turn), its
# Turn.Server killed while paused, then new input on the restarted server (decision 27 F3).
# Part B: a cited text block replayed on the next request (Claudio 0.7.1, decision 27 B3).
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, ToolCallResponse, Turn}
alias Normandy.Behaviours.SessionRegistry.Native
alias Normandy.Behaviours.SessionStore.InMemory
alias Normandy.Components.{AgentMemory, Message}
alias Normandy.MCP.ServerConfig

defmodule E2E.S16.RecordCity do
  defmodule Input do
    use Normandy.Schema

    io_schema "Record the city your answer names." do
      field(:city, :string, required: true, description: "the city")
    end
  end

  use Normandy.Tool,
    name: "record_city",
    description: "Record the city your answer names. Call it in the same reply as the answer.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{city: city}}), do: {:ok, "recorded #{city}"}
end

S.start("16_mcp_pause", cap: 8)

# Public MCP servers that need no authorization, tried in order. One tool, called once per
# item in sequence: 12 calls overrun the API's server-side loop (10 iterations).
candidates = [
  %{
    name: "deepwiki",
    url: "https://mcp.deepwiki.com/mcp",
    tool: "read_wiki_structure",
    items:
      ~w(elixir-lang/elixir phoenixframework/phoenix elixir-ecto/ecto elixir-plug/plug
         wojtekmach/req dashbitco/broadway elixir-nx/nx phoenixframework/phoenix_live_view
         sorentwo/oban absinthe-graphql/absinthe elixir-mint/mint beam-telemetry/telemetry)
  },
  %{
    name: "fetch",
    url: "https://remote.mcpservers.org/fetch/mcp",
    tool: "fetch",
    items: for(n <- 1..12, do: "https://example.com/?item=#{n}")
  }
]

# Reachable from this machine is not proof the API reaches it, but an unreachable one is
# certainly skipped.
reachable? = fn %{url: url} ->
  body = %{
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: %{
      protocolVersion: "2025-06-18",
      capabilities: %{},
      clientInfo: %{name: "normandy-e2e", version: "0"}
    }
  }

  case Req.post(url,
         json: body,
         headers: [{"accept", "application/json, text/event-stream"}],
         receive_timeout: 10_000,
         retry: false
       ) do
    {:ok, %Req.Response{status: 200}} -> true
    _other -> false
  end
end

prompt = fn %{tool: tool, items: items} ->
  "Call the #{tool} tool exactly once for each of the #{length(items)} items below, strictly " <>
    "one call at a time: make one call, wait for its result, then make the next. Never put two " <>
    "tool calls in one step. After the last call, reply with one short line per item.\n" <>
    Enum.map_join(items, "\n", &("- " <> &1))
end

agent_for = fn server, name ->
  BaseAgent.init(%{
    client: S.client(%{recv_timeout: 240_000}),
    model: S.model(),
    max_tokens: 4_000,
    name: name,
    max_tool_iterations: 3,
    mcp_servers: [ServerConfig.new(server.name, server.url) |> ServerConfig.allow_tools([server.tool])]
  })
end

paused_entry? = fn
  %{role: "assistant", content: %ToolCallResponse{stop_reason: reason}} -> reason in [:pause_turn, "pause_turn"]
  _other -> false
end

accepted? = fn
  {:ok, %{chat_message: text}} when is_binary(text) -> String.trim(text) != ""
  {:ok, _config, %{chat_message: text}} when is_binary(text) -> String.trim(text) != ""
  {:ok, %Claudio.Messages.Response{}} -> true
  _other -> false
end

followup = "Stop the lookups now. In one sentence, how many items do you have results for?"

# The paused shape rebuilt from a real MCP response: cut after its first mcp_tool_use
# (dropping that call's result), stored as a paused turn, then new input.
synthetic_mcp = fn server ->
  config = agent_for.(server, "s16-synthetic")
  ask = %BaseAgentInputSchema{chat_message: "Call #{server.tool} once for #{hd(server.items)}, then answer in one sentence."}
  config = %{config | memory: AgentMemory.add_message(config.memory, "user", ask)}

  # get_response raises on a failed call; report it as a scenario failure with usage.
  blocks =
    try do
      %ToolCallResponse{content_blocks: blocks} = BaseAgent.get_response(config, %ToolCallResponse{})
      blocks
    rescue
      error ->
        S.assert!("the rebuilt pause's source call succeeds", false, Exception.format(:error, error, __STACKTRACE__))
    catch
      kind, reason ->
        S.assert!("the rebuilt pause's source call succeeds", false, "#{kind}: #{inspect(reason)}")
    end

  case Enum.find_index(blocks, &(&1["type"] == "mcp_tool_use")) do
    nil ->
      S.assert!("the model called the MCP tool (material for the rebuilt pause)", false, inspect(blocks))

    i ->
      paused = %ToolCallResponse{content_blocks: Enum.take(blocks, i + 1), stop_reason: :pause_turn}
      config = %{config | memory: AgentMemory.add_message(config.memory, "assistant", paused)}
      IO.puts("PAUSE_PATH synthetic_mcp")
      BaseAgent.run(config, %{chat_message: followup})
  end
end

# The same shape with the API's web_search server tool, through Claudio: Normandy cannot
# declare server tools.
synthetic_web = fn ->
  alias Claudio.Messages.{Request, Response}
  client = Claudio.Client.new(%{token: S.api_key!(), version: "2023-06-01"})

  request =
    Request.new(S.model())
    |> Request.set_max_tokens(1_000)
    |> Request.add_web_search_tool(version: :basic)
    |> Request.add_message(:user, "Search the web once for the Elixir programming language, then answer in one sentence.")

  # A raise, throw or exit from the direct Claudio call is a reported failure too.
  create = fn req, label ->
    try do
      Claudio.Messages.create(client, req)
    rescue
      error -> S.assert!(label, false, Exception.format(:error, error, __STACKTRACE__))
    catch
      kind, reason -> S.assert!(label, false, "#{kind}: #{inspect(reason)}")
    end
  end

  blocks =
    case create.(request, "the web_search source call succeeds") do
      {:ok, response} -> Response.to_assistant_content(response)
      {:error, error} -> S.assert!("the web_search source call succeeds", false, inspect(error))
    end

  case Enum.find_index(blocks, &(&1["type"] == "server_tool_use")) do
    nil ->
      S.assert!("the model searched (material for the rebuilt pause)", false, inspect(blocks))

    i ->
      IO.puts("PAUSE_PATH synthetic_web_search")

      request
      |> Request.add_message(:assistant, Enum.take(blocks, i + 1))
      |> Request.add_message(:user, "Answer in one sentence without searching again.")
      |> then(&create.(&1, "the web_search follow-up call returns"))
  end
end

S.narrate("Part A: a paused MCP-connector turn, its server killed, then new input.")
server = Enum.find(candidates, reachable?)

result =
  if server do
    S.narrate("Live: #{server.name} (#{server.url}), #{length(server.items)} sequential #{server.tool} calls in one turn.")
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "e2e-pause-#{System.unique_integer([:positive])}"
    scenario = self()
    armed = :atomics.new(1, [])

    # Runs in the Turn.Server process. The :iteration event after a paused response comes
    # after that response is in the store; tell the scenario, then wait to be killed.
    subscriber = fn
      :iteration, %{iteration: i} when i > 1 ->
        {:ok, entries} = InMemory.history(store, sid)
        last = entries |> Enum.reverse() |> Enum.find(&(&1.role == "assistant"))

        if paused_entry?.(last) and :atomics.compare_exchange(armed, 1, 0, 1) == :ok do
          send(scenario, {:paused, self()})

          receive do
            :release -> :ok
          after
            60_000 -> :ok
          end
        end

      _name, _meta ->
        :ok
    end

    session =
      Turn.Session.new(
        session_id: sid,
        config: agent_for.(server, "s16"),
        store: {InMemory, store},
        registry: {Native, reg},
        supervisor: sup,
        subscriber: subscriber
      )

    task =
      Task.async(fn ->
        try do
          Turn.Session.run(session, %{chat_message: prompt.(server)})
        rescue
          error -> {:raised, Exception.format(:error, error, __STACKTRACE__)}
        catch
          :exit, reason -> {:exited, reason}
          :throw, value -> {:raised, "throw: " <> inspect(value)}
        end
      end)

    receive do
      {:paused, pid} ->
        S.narrate("The turn paused (pause_turn); killing its Turn.Server before the continuation.")
        Process.exit(pid, :kill)
        first =
          case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, first} -> first
            {:exit, reason} -> {:exited, reason}
            nil -> S.assert!("the killed turn's caller returns within 30 s", false, "no return after the kill")
          end

        S.assert!("the caller of the killed turn gets an exit, not an answer", match?({:exited, _}, first), inspect(first))

        new_pid =
          S.wait_for(
            fn ->
              case Native.whereis(reg, sid) do
                {:ok, p} when p != pid -> p
                _ -> nil
              end
            end,
            10_000,
            "the supervisor restarts the session server"
          )

        S.narrate("Restarted as #{inspect(new_pid)}; new input on the paused history.")

        # Own deadline, above the call's recv_timeout (240 s); the exit is a failed result below.
        follow_task =
          Task.async(fn ->
            try do
              Turn.Session.run(session, %{chat_message: followup})
            rescue
              error -> {:raised, Exception.format(:error, error, __STACKTRACE__)}
            catch
              :exit, reason -> {:exited, reason}
              :throw, value -> {:raised, "throw: " <> inspect(value)}
            end
          end)

        result =
          case Task.yield(follow_task, 270_000) || Task.shutdown(follow_task, :brutal_kill) do
            {:ok, result} -> result
            _timeout -> S.assert!("the follow-up turn answers within 270 s", false, "no answer")
          end

        S.assert!("the follow-up Session.run does not raise", not match?({:raised, _}, result), inspect(result))
        {:ok, entries} = InMemory.history(store, sid)
        i = Enum.find_index(entries, paused_entry?)
        S.assert!("the store holds the paused assistant turn", is_integer(i), inspect(Enum.map(entries, & &1.role)))
        S.assert!("the new input directly follows the paused turn", Enum.at(entries, i + 1).role == "user", inspect(Enum.map(entries, & &1.role)))
        IO.puts("PAUSE_PATH live")
        result

      {ref, first} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case first do
          {:ok, _output} ->
            S.narrate("No pause_turn: the server-side loop finished the turn. Rebuilding the paused shape.")
            synthetic_mcp.(server)

          failed ->
            # {:error, _} may be the API failing to reach the chosen MCP server: not a finished turn.
            S.assert!("the first turn ends without an error", false, inspect(failed))
        end
    after
      270_000 -> S.assert!("the first turn pauses or finishes within 270 s", false, "neither happened")
    end
  else
    S.narrate("No candidate MCP server answered an initialize from here; rebuilding the shape with web_search.")
    synthetic_web.()
  end

S.assert!("the API accepts new input after a paused turn", accepted?.(result), inspect(result))
IO.puts("PAUSE_SHAPE accepted")

S.narrate("Part B: a cited answer and a tool call in one reply; the cited block is replayed.")

doc = %{
  "type" => "document",
  "source" => %{
    "type" => "text",
    "media_type" => "text/plain",
    "data" => "The capital of France is Paris. Paris has about two million residents."
  },
  "title" => "France facts",
  "citations" => %{"enabled" => true}
}

cited =
  BaseAgent.init(%{client: S.client(), model: S.model(), max_tokens: 800, name: "s16b", max_tool_iterations: 2})
  |> BaseAgent.register_tool(struct!(E2E.S16.RecordCity))

cited = %{cited | memory: AgentMemory.add_message(cited.memory, "user", [doc, %{"type" => "text", "text" => "Read the document above."}])}

case BaseAgent.run(cited, %{
       chat_message:
         "In one reply: state France's capital in one sentence, citing the document, and call " <>
           "record_city with that city."
     }) do
  {:ok, cited, %{chat_message: text}} ->
    S.turn(1, "cite and record", text)

    blocks =
      for %Message{role: "assistant", content: %ToolCallResponse{content_blocks: b}} <-
            AgentMemory.messages(cited.memory),
          block <- b,
          block["type"] == "text" and is_list(block["citations"]),
          do: block

    S.assert!("the tool-call turn carried a cited text block (else the replay was not exercised)", blocks != [], inspect(AgentMemory.messages(cited.memory)))
    IO.puts("CITATIONS_REPLAY accepted (#{length(blocks)} cited block(s))")

  {:error, error} ->
    S.assert!("the API accepts the replayed cited turn", false, Exception.message(error))
end

S.finish()
