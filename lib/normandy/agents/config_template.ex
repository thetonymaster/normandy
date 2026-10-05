defmodule Normandy.Agents.ConfigTemplate do
  @moduledoc """
  Splits a `%BaseAgentConfig{}` into a serializable, secret-free **template**
  (persisted via `SessionStore.save_config_template/3`) and reconstructs a full
  config on any node from `template + node-local supplement + credential token`.

  Excluded from the template (resolved node-locally instead): `client` (built from
  the token), `tool_registry` and `before/after_hooks` (from the supplement), and
  `circuit_breaker` and `mcp_servers` (from the supplement; the template records
  only that they were set, and `rebuild/3` raises if the supplement lacks one).
  `current_user_input` and `resolved_context_window` are transient and not kept.

  Everything else travels in the template: model and sampling settings, tool
  limits, prompt, schemas, memory cap, `initial_memory`, `retry_options`, JSON
  retry settings, guardrails, `tool_context`, behaviour module refs and hook entries
  (`Normandy.Behaviours.Hooks`; their opts must be plain data and hold no secrets).
  These must be plain data: `from_config/2` raises on a function or pid (e.g. a `:retry_if` fun).
  `tool_context` must hold no secrets: the template is stored in plaintext.
  A template saved before these fields existed rebuilds with their defaults.
  """
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory

  # Plain-data config fields carried as-is. A template saved before 2.0 lacks
  # them, so `rebuild/3` leaves the struct defaults in place for missing keys.
  @data_fields [
    :initial_memory,
    :retry_options,
    :enable_json_retry,
    :json_retry_max_attempts,
    :input_guardrails,
    :output_guardrails,
    :output_guardrails_streaming_mode,
    :output_guardrails_chunk_size,
    :output_guardrails_on_violation,
    :tool_context
  ]

  # Fields a template cannot hold (a linked pid; MCP settings that may carry an
  # authorization token). The template records which were set, and `rebuild/3`
  # takes them from the supplement.
  @node_local_fields [:circuit_breaker, :mcp_servers]

  @spec from_config(BaseAgentConfig.t(), String.t()) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id) do
    b = c.behaviours || %Config{}

    %{
      template_id: template_id,
      resume_policy: :lazy,
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
        session_registry: b.session_registry,
        hooks: storable_hooks!(b.hooks)
      }
    }
    |> Map.merge(storable_fields!(c))
    |> Map.put(:node_local_fields, Enum.reject(@node_local_fields, &(Map.fetch!(c, &1) == nil)))
  end

  # Hook entries travel as given; validate_entries!/2 (load: false) refuses opts that
  # are not plain data, as unstorable?/1 does for the fields above.
  defp storable_hooks!(hooks) do
    :ok = Hooks.validate_entries!(hooks, load: false)
    hooks
  end

  # A function or pid would be persisted as a term that only works on this
  # node and this code version, so refuse it here rather than at rebuild.
  defp storable_fields!(c) do
    fields = Map.take(Map.from_struct(c), @data_fields)

    Enum.each(fields, fn {key, value} ->
      if unstorable?(value) do
        raise ArgumentError,
              "ConfigTemplate.from_config/2: #{inspect(key)} contains a function or pid, " <>
                "which a template cannot store. Keep it to plain data (modules, atoms, " <>
                "numbers, strings, lists, maps)."
      end
    end)

    fields
  end

  defp unstorable?(value) when is_function(value) or is_pid(value), do: true
  defp unstorable?(value) when is_list(value), do: Enum.any?(value, &unstorable?/1)
  defp unstorable?(value) when is_tuple(value), do: value |> Tuple.to_list() |> unstorable?()

  defp unstorable?(value) when is_struct(value), do: value |> Map.from_struct() |> unstorable?()

  defp unstorable?(value) when is_map(value),
    do: Enum.any?(value, fn {k, v} -> unstorable?(k) or unstorable?(v) end)

  defp unstorable?(_value), do: false

  @spec from_config(BaseAgentConfig.t(), String.t(), :lazy | :eager) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id, resume_policy) do
    from_config(c, template_id) |> Map.put(:resume_policy, resume_policy)
  end

  @doc """
  Rebuilds a `BaseAgentConfig` from a template and a supplement.

  Raises `ArgumentError` for a compaction setup that can't size its window (see
  `BaseAgent.validate_compaction_config!/1`), and for a malformed hook entry in the
  template (shape, `:on_error` and plain-data opts; whether the hook module exists on
  this node is checked later, by `Turn.Server`).
  """
  @spec rebuild(map(), Normandy.Behaviours.AgentTemplate.supplement(), String.t()) ::
          BaseAgentConfig.t()
  def rebuild(tmpl, supplement, token) do
    refs = tmpl.behaviours_refs
    :ok = Hooks.validate_entries!(Map.get(refs, :hooks, []), load: false)

    behaviours = %Config{
      policy: refs.policy,
      budget: refs.budget,
      credential: refs.credential,
      compactor: refs.compactor,
      model_catalog: refs.model_catalog,
      session_store: refs.session_store,
      session_registry: refs.session_registry,
      hooks: Map.get(refs, :hooks, []),
      before_hooks: supplement.before_hooks,
      after_hooks: supplement.after_hooks
    }

    %BaseAgentConfig{
      model: tmpl.model,
      temperature: tmpl.temperature,
      # Templates saved by 1.x store nil for an unset max_tokens; 2.0 sends the default.
      max_tokens: tmpl.max_tokens || BaseAgentConfig.default_max_tokens(),
      max_tool_iterations: tmpl.max_tool_iterations,
      max_tool_concurrency: tmpl.max_tool_concurrency,
      name: tmpl.name,
      prompt_specification: tmpl.prompt_specification,
      input_schema: tmpl.input_schema,
      output_schema: tmpl.output_schema,
      tool_registry: supplement.tool_registry,
      client: supplement.client_builder.(token),
      behaviours: behaviours,
      memory: AgentMemory.new_memory(Map.get(tmpl, :max_messages))
    }
    |> struct(Map.take(tmpl, @data_fields))
    |> struct(node_local_fields!(tmpl, supplement))
    |> BaseAgent.validate_compaction_config!()
    |> validate_client_options!()
  end

  defp node_local_fields!(tmpl, supplement) do
    tmpl
    |> Map.get(:node_local_fields, [])
    |> Map.new(fn key ->
      case Map.fetch(supplement, key) do
        {:ok, value} when value != nil ->
          {key, value}

        _ ->
          raise ArgumentError,
                "ConfigTemplate.rebuild/3: template #{inspect(tmpl.template_id)} was saved " <>
                  "with #{inspect(key)} set, but the supplement has no #{inspect(key)}. " <>
                  "Add it to the supplement registered for this template on every node."
      end
    end)
  end

  defp validate_client_options!(%BaseAgentConfig{client: client} = config) do
    _ = BaseAgent.validate_client_options!(client)
    config
  end
end
