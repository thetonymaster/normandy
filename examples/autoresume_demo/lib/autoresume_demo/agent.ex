defmodule AutoresumeDemo.Agent do
  @moduledoc """
  Builds the demo agent's config, the node-local Catalog supplement, and the
  persisted eager ConfigTemplate. The `client_builder/0` closure is the single
  real-vs-simulated switch — and the only seam carried through Tier-2
  reconstruction on a surviving node after a handoff.
  """
  alias Normandy.Agents.{BaseAgent, ConfigTemplate}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Components.PromptSpecification
  alias Normandy.Tools.Registry
  alias AutoresumeDemo.SimClient
  alias AutoresumeDemo.Tools.ResearchStep

  @template_id "research"
  @topic "distributed systems"

  def template_id, do: @template_id
  def topic, do: @topic
  def total_steps, do: 6
  def model, do: Application.get_env(:autoresume_demo, :demo_model)

  def tool_registry, do: Registry.new([%ResearchStep{}])

  @doc "The single real/sim switch. Carried through Tier-2 reconstruction."
  def client_builder do
    topic = @topic
    steps = total_steps()

    # Read the runtime env INSIDE the closure: this closure is stored in the
    # Catalog supplement and invoked later during a handoff, so it must reflect
    # the env at INVOCATION time, not at the moment client_builder/0 was called.
    fn token ->
      mode = Application.get_env(:autoresume_demo, :demo_mode, :real)
      delay = Application.get_env(:autoresume_demo, :sim_step_delay_ms, 1500)

      case mode do
        :simulated ->
          %SimClient{topic: topic, total_steps: steps, step_delay_ms: delay}

        _ ->
          %Normandy.LLM.ClaudioAdapter{api_key: token, options: %{timeout: 60_000}}
      end
    end
  end

  def base_config do
    BaseAgent.init(%{
      client: client_builder().(System.get_env("ANTHROPIC_API_KEY") || "SIMULATED-NO-KEY"),
      model: model(),
      temperature: 0.7,
      max_tokens: 1024,
      # total_steps tool calls + 1 finalizing call
      max_tool_iterations: total_steps() + 1,
      tool_registry: tool_registry(),
      name: "researcher",
      prompt_specification: %PromptSpecification{
        background: ["You research a topic step by step using the research_step tool."],
        steps: [
          "Call research_step once per step with the next step number n (1..#{total_steps()}).",
          "After #{total_steps()} steps, stop calling tools and write a 2-sentence synthesis."
        ],
        output_instructions: ["Be concise."]
      },
      # Credential ref travels in the template via from_config; client/tools/hooks
      # are resolved node-locally from the supplement.
      behaviours: %Normandy.Behaviours.Config{
        credential: {AutoresumeDemo.EnvCredentialProvider, []}
      }
    })
  end

  def build_template, do: ConfigTemplate.from_config(base_config(), @template_id, :eager)

  @doc """
  Warm a node so any `[:safe]` decode of a persisted demo blob can succeed there.

  The Postgres `SessionStore` decodes both the persisted **ConfigTemplate** (in
  `Turn.Server.reconstruct_config!/3`) and the persisted **Turn.State** (in
  `load_turn_state/2`) with `:erlang.binary_to_term(blob, [:safe])`. `[:safe]`
  rejects any atom not already interned on the decoding node. A node that has only
  run `Application.ensure_all_started/1` (a freshly-booted worker peer) — or the
  observer/test VM that merely starts the Repo + registry — has NOT lazily loaded
  every Normandy module, so the struct-field/map-key atoms minted by those modules
  are absent and the decode raises `:badarg`. Examples seen in practice:

    * ConfigTemplate keys: `:behaviours_refs`, `:max_messages`,
      `:max_tool_concurrency`, `:output_schema`, `:chat_message`
    * Turn.State keys: `:iterations_left`, `:awaiting_final`, `:stop_reason`, ...

  Building the template + base config + a sample Turn.State here force-loads those
  modules and interns the atoms; the round-trip `[:safe]` decodes assert the
  postcondition (they raise if any reachable atom is still missing), so callers can
  treat `:ok` as a hard guarantee that this node can decode demo blobs.

  Idempotent and cheap; safe to call on every node (workers AND observer) at boot.
  """
  @spec warmup() :: :ok
  def warmup do
    tmpl = build_template()
    _ = base_config()
    # A sample Turn.State exercises every Turn.State field atom (the persisted shape
    # the observer/reaper later decode under [:safe]).
    state = %Normandy.Agents.Turn.State{}

    # Round-trip through the SAME [:safe] path the store uses; raises if any reachable
    # atom is still un-interned on this node.
    ^tmpl = :erlang.binary_to_term(:erlang.term_to_binary(tmpl), [:safe])
    ^state = :erlang.binary_to_term(:erlang.term_to_binary(state), [:safe])
    :ok
  end

  def supplement do
    %{
      tool_registry: tool_registry(),
      before_hooks: [],
      after_hooks: [],
      client_builder: client_builder()
    }
  end

  def register_supplement(catalog), do: Catalog.put(catalog, @template_id, supplement())
end
