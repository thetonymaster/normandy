# e2e/12_mcp_a2a.exs — agent A uses a stdio MCP tool and asks agent B over A2A HTTP, across 3 turns.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Components.PromptSpecification

defmodule E2E.S12.Router do
  use Plug.Router, copy_opts_to_assign: :b

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/.well-known/agent-card.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Claudio.A2A.AgentCard.to_map(Agent.get(E2E.S12.Card, & &1))))
  end

  post "/a2a" do
    %{"id" => id, "method" => "message/send", "params" => %{"message" => m}} = conn.body_params
    Agent.update(E2E.S12.Hits, &(&1 + 1))
    {:ok, task} = Normandy.A2A.Server.handle_message(conn.assigns.b.config, Claudio.A2A.Message.from_map(m), conn.req_headers)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => Claudio.A2A.Task.to_map(task)}))
  end
end

S.start("12_mcp_a2a", cap: 10)
{:ok, _} = Agent.start_link(fn -> 0 end, name: E2E.S12.Hits)
# The card names the server's URL, which exists only once the OS picks the port.
{:ok, _} = Agent.start_link(fn -> nil end, name: E2E.S12.Card)

S.narrate("Agent B (Harbour Office) behind A2A on a random local port.")
b_config =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 150,
    name: "harbour-office",
    prompt_specification: %PromptSpecification{
      background: ["You are the Harbour Office. The harbour opens at 05:40. The duty officer is Captain Ilse Varga. Answer briefly."]
    }
  })

{:ok, _} = Plug.Cowboy.http(E2E.S12.Router, %{config: b_config}, port: 0)
port = :ranch.get_port(E2E.S12.Router.HTTP)
base = "http://127.0.0.1:#{port}"
card = Normandy.A2A.Server.build_agent_card(b_config, name: "Harbour Office", description: "Answers questions about the harbour", url: base <> "/a2a")
:ok = Agent.update(E2E.S12.Card, fn nil -> card end)

card_resp = Req.get!(base <> "/.well-known/agent-card.json")
S.assert!("the agent card is served over HTTP", card_resp.status == 200 and card_resp.body["name"] == "Harbour Office", inspect(card_resp.body))

S.narrate("MCP: spawn the stdio city server and discover its tools.")
{:ok, mcp} =
  ExMCP.Client.start_link(
    transport: :stdio,
    command: ["elixir", Path.expand("mcp_city_server.exs", __DIR__)],
    protocol_mode: :legacy_only
  )

{:ok, registry} =
  Normandy.MCP.Registry.discover_and_register(Normandy.Tools.Toolset.new(), Claudio.MCP.Adapters.ExMCP, mcp, prefix: "city")

S.assert!("MCP tool registered with its prefix", Normandy.Tools.Toolset.has_tool?(registry, "city__lookup_city"), inspect(registry))

harbour = Normandy.A2A.AgentTool.new(base <> "/a2a", card, prefix: "harbour", transport_opts: [receive_timeout: 60_000])

agent =
  BaseAgent.init(%{client: S.client(), model: S.model(), max_tokens: 300, name: "s12", toolset: registry, max_tool_iterations: 4})
  |> BaseAgent.register_tool(harbour, timeout: 60_000)

turns = [
  "What is the population of Zubrowka? Use the city lookup tool.",
  "Ask the Harbour Office when the harbour opens and who the duty officer is.",
  "Ask the Harbour Office once more who is on duty today, and remind me of Zubrowka's population."
]

{_agent, replies} =
  turns
  |> Enum.with_index(1)
  |> Enum.map_reduce(agent, fn {text, n}, agent ->
    {:ok, agent, r} = BaseAgent.run(agent, %{chat_message: text})
    S.turn(n, text, r.chat_message)
    {r.chat_message, agent}
  end)
  |> then(fn {replies, agent} -> {agent, replies} end)

population? = fn text -> S.recalls?(text, "4321987") or S.recalls?(text, "4,321,987") end
[r1, r2, r3] = replies
S.assert!("turn 1 answer came from the MCP tool", population?.(r1), r1)
S.assert!("turn 2 relays the harbour opening time from agent B", S.recalls?(r2, "05:40") or S.recalls?(r2, "5:40"), r2)
S.assert!("turn 2 relays the duty officer from agent B", S.recalls?(r2, "Varga"), r2)
S.assert!("turn 3 asks B again and remembers turn 1", S.recalls?(r3, "Varga") and population?.(r3), r3)
hits = Agent.get(E2E.S12.Hits, & &1)
S.assert!("agent A called agent B over HTTP at least twice", hits >= 2, "#{hits} A2A requests")

S.finish()
