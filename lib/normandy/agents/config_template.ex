defmodule Normandy.Agents.ConfigTemplate do
  @moduledoc """
  Splits a `%BaseAgentConfig{}` into a serializable, secret-free **template**
  (persisted via `SessionStore.save_config_template/3`) and reconstructs a full
  config on any node from `template + node-local supplement + credential token`.

  Excluded from the template (resolved node-locally instead): `client` (built from
  the token), `tool_registry` (from the supplement), and `before/after_hooks`
  (from the supplement). Behaviour module refs travel in the template; their
  `opts` must be serializable.
  """
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.Config

  @spec from_config(BaseAgentConfig.t(), String.t()) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id) do
    b = c.behaviours || %Config{}

    %{
      template_id: template_id,
      model: c.model,
      temperature: c.temperature,
      max_tokens: c.max_tokens,
      max_tool_iterations: c.max_tool_iterations,
      max_tool_concurrency: c.max_tool_concurrency,
      name: c.name,
      prompt_specification: c.prompt_specification,
      input_schema: c.input_schema,
      output_schema: c.output_schema,
      max_messages: (c.memory && c.memory.max_messages) || nil,
      behaviours_refs: %{
        policy: b.policy,
        budget: b.budget,
        credential: b.credential,
        compactor: b.compactor,
        model_catalog: b.model_catalog,
        session_store: b.session_store,
        session_registry: b.session_registry
      }
    }
  end

  @spec rebuild(map(), Normandy.Behaviours.AgentTemplate.supplement(), String.t()) ::
          BaseAgentConfig.t()
  def rebuild(tmpl, supplement, token) do
    refs = tmpl.behaviours_refs

    behaviours = %Config{
      policy: refs.policy,
      budget: refs.budget,
      credential: refs.credential,
      compactor: refs.compactor,
      model_catalog: refs.model_catalog,
      session_store: refs.session_store,
      session_registry: refs.session_registry,
      before_hooks: supplement.before_hooks,
      after_hooks: supplement.after_hooks
    }

    %BaseAgentConfig{
      model: tmpl.model,
      temperature: tmpl.temperature,
      max_tokens: tmpl.max_tokens,
      max_tool_iterations: tmpl.max_tool_iterations,
      max_tool_concurrency: tmpl.max_tool_concurrency,
      name: tmpl.name,
      prompt_specification: tmpl.prompt_specification,
      input_schema: tmpl.input_schema,
      output_schema: tmpl.output_schema,
      tool_registry: supplement.tool_registry,
      client: supplement.client_builder.(token),
      behaviours: behaviours,
      memory: Normandy.Components.AgentMemory.new_memory(tmpl[:max_messages])
    }
  end
end
