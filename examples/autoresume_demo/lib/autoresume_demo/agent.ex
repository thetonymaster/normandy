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
