defmodule Normandy.Agents.ConfigTemplate do
  @moduledoc """
  Splits a `%BaseAgentConfig{}` into a serializable, secret-free **template**
  (persisted via `SessionStore.save_config_template/3`) and reconstructs a full
  config on any node from `template + node-local supplement + credential token`.

  Excluded from the template (resolved node-locally instead): `client` (built from
  the token), `toolset` and `before/after_hooks` (from the supplement), and
  `mcp_servers` (from the supplement; the template records only that it was set, and
  `rebuild/3` raises if the supplement lacks it).
  `current_user_input` and `resolved_context_window` are transient and not kept.

  Everything else travels in the template: model and sampling settings, tool
  limits, prompt, schemas, memory cap, `initial_memory`, the `retry` and
  `circuit_breaker` options (the breaker itself is the node's shared breaker for that key,
  `BaseAgentConfig.circuit_breaker_key/1`), JSON retry settings, `guardrails`, `tool_context`,
  behaviour module refs and hook entries (`Normandy.Behaviours.Hooks`; their opts must
  be plain data and hold no secrets). These must be plain data: `from_config/2` raises
  on a function or pid (e.g. a `:retry_if` fun). `tool_context` must hold no secrets:
  the template is stored in plaintext.

  ## Templates saved by Normandy 1.0

  `rebuild/3` reads templates written by Normandy 1.0.0 and by 2.0. A 1.0 template lacks
  the fields 2.0 added (they rebuild with their defaults) and differs in three ways, which
  `rebuild/3` translates:

    * `max_tokens: nil` (the agent set none) rebuilds with
      `BaseAgentConfig.default_max_tokens/0`;
    * `behaviours_refs` carries `session_store` and `session_registry`, slots 1.0 never
      read; they are dropped;
    * a `Normandy.Behaviours.Compactor.WindowManager` ref pins the window with
      `:max_tokens`, which 2.0 calls `:context_window`. A custom compactor's opts are
      left as they are.

  Any other field, a `behaviours_refs` slot or a `node_local_fields` entry that neither
  version writes, and a missing required field, raise `ArgumentError` naming it. Templates
  written by unreleased 2.0 builds are not translated.
  """
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Tools.Toolset

  # Plain-data config fields carried as-is. A 1.0 template lacks them, so
  # `rebuild/3` leaves the struct defaults in place for missing keys.
  @data_fields [
    :initial_memory,
    :retry,
    :circuit_breaker,
    :enable_json_retry,
    :json_retry_max_attempts,
    :guardrails,
    :tool_context,
    :max_tool_result_chars
  ]

  # Fields a template cannot hold (MCP settings that may carry an authorization token).
  # The template records whether it was set, and `rebuild/3` takes it from the supplement.
  @node_local_fields [:mcp_servers]

  # Top-level fields rebuild/3 reads with no default: both 1.0 and 2.0 templates have them.
  @required_fields [
    :template_id,
    :model,
    :temperature,
    :max_tokens,
    :max_tool_iterations,
    :max_tool_concurrency,
    :name,
    :prompt_specification,
    :input_schema,
    :output_schema,
    :behaviours_refs
  ]

  # Fields read when present: 1.0 wrote resume_policy and max_messages too;
  # Turn.Session adds server_options (the Turn.Server options it was started with).
  @optional_fields [
    :resume_policy,
    :max_messages,
    :node_local_fields,
    :server_options | @data_fields
  ]

  @required_refs [:policy, :budget, :credential, :compactor, :model_catalog]
  @optional_refs [:hooks]

  # 1.0's session slots: never read by 1.0's turn loop, so dropping them loses nothing.
  @dropped_v1_refs [:session_store, :session_registry]

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
              "Normandy.Agents.ConfigTemplate.from_config/2: #{inspect(key)} contains a function or pid, " <>
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

  Translates a template saved by Normandy 1.0 (see the moduledoc). Raises
  `ArgumentError` naming the field for one it cannot translate, for a `max_tokens` that is
  neither `nil` (1.0) nor a positive integer, for a compaction setup that can't size its
  window or whose compactor opts are malformed, and for a malformed hook entry in
  the template (shape, `:on_error` and plain-data opts; whether the hook module exists on
  this node is checked later, by `Turn.Server`). Raises `ArgumentError` for a supplement
  that still uses the 1.x key `:tool_registry`, whose `:toolset` is not a
  `%Normandy.Tools.Toolset{}` or `nil`, or whose toolset holds a struct whose module does not
  implement `Normandy.Tool`.
  """
  @spec rebuild(map(), Normandy.Behaviours.AgentTemplate.supplement(), String.t()) ::
          BaseAgentConfig.t()
  def rebuild(tmpl, supplement, token) when is_map(tmpl) do
    tmpl = translate!(tmpl)
    refs = tmpl.behaviours_refs
    :ok = Hooks.validate_entries!(Map.get(refs, :hooks, []), load: false)

    behaviours = %Config{
      policy: refs.policy,
      budget: refs.budget,
      credential: refs.credential,
      compactor: refs.compactor,
      model_catalog: refs.model_catalog,
      hooks: Map.get(refs, :hooks, []),
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
      toolset: supplement_toolset!(supplement),
      client: supplement.client_builder.(token),
      behaviours: behaviours,
      memory: AgentMemory.new_memory(Map.get(tmpl, :max_messages))
    }
    |> struct(Map.take(tmpl, @data_fields))
    |> struct(node_local_fields!(tmpl, supplement))
    |> BaseAgent.validate_compaction_config!({__MODULE__, :rebuild, 3})
    |> validate_client_options!()
  end

  # A 1.0 or 2.0 template -> the 2.0 shape; anything else raises naming the field.
  defp translate!(tmpl) do
    id = Map.get(tmpl, :template_id)
    :ok = check_fields!(tmpl, id)

    tmpl
    |> Map.update!(:max_tokens, &max_tokens!(&1, id))
    |> Map.update!(:behaviours_refs, &translate_refs!(&1, id))
  end

  defp check_fields!(tmpl, id) do
    case Map.keys(tmpl) -- (@required_fields ++ @optional_fields) do
      [] -> :ok
      [field | _] -> untranslatable!(id, "has the field #{inspect(field)}")
    end

    case @required_fields -- Map.keys(tmpl) do
      [] -> :ok
      [field | _] -> missing!(id, "the field #{inspect(field)}")
    end

    case Map.get(tmpl, :node_local_fields, []) -- @node_local_fields do
      [] -> :ok
      [field | _] -> untranslatable!(id, "lists #{inspect(field)} in :node_local_fields")
    end
  end

  # 1.0 stored nil for an unset max_tokens; 2.0 always stores a positive integer.
  defp max_tokens!(nil, _id), do: BaseAgentConfig.default_max_tokens()
  defp max_tokens!(n, _id) when is_integer(n) and n > 0, do: n

  defp max_tokens!(other, id) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(id)} has max_tokens " <>
            "#{inspect(other)}; expected a positive integer, or nil (a 1.0 template that " <>
            "set none)"
  end

  defp translate_refs!(refs, id) when is_map(refs) do
    refs = Map.drop(refs, @dropped_v1_refs)

    case Map.keys(refs) -- (@required_refs ++ @optional_refs) do
      [] -> :ok
      [slot | _] -> untranslatable!(id, "has the behaviours_refs slot #{inspect(slot)}")
    end

    case @required_refs -- Map.keys(refs) do
      [] -> :ok
      [slot | _] -> missing!(id, "the behaviours_refs slot #{inspect(slot)}")
    end

    Map.update!(refs, :compactor, &compactor_ref!(&1, id))
  end

  defp translate_refs!(_refs, id),
    do: untranslatable!(id, "has a behaviours_refs that is not a map")

  # 1.0's WindowManager pinned the window with :max_tokens; 2.0 calls it :context_window.
  # Only Normandy's own compactor: a custom compactor's :max_tokens is its own option.
  defp compactor_ref!({Compactor.WindowManager, opts}, id) when is_list(opts) do
    case {Keyword.fetch(opts, :max_tokens), Keyword.has_key?(opts, :context_window)} do
      {:error, _pinned?} ->
        {Compactor.WindowManager, opts}

      {{:ok, _window}, true} ->
        untranslatable!(
          id,
          "has Compactor.WindowManager opts with both :max_tokens (1.0) and :context_window (2.0)"
        )

      {{:ok, window}, false} ->
        {Compactor.WindowManager,
         opts |> Keyword.delete(:max_tokens) |> Keyword.put(:context_window, window)}
    end
  end

  defp compactor_ref!(ref, _id), do: ref

  @spec untranslatable!(term(), String.t()) :: no_return()
  defp untranslatable!(id, what) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(id)} #{what}, which neither a " <>
            "Normandy 1.0 nor a 2.0 template has; it cannot be rebuilt (MIGRATING-2.0.md §22)"
  end

  @spec missing!(term(), String.t()) :: no_return()
  defp missing!(id, what) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(id)} lacks #{what}, which every " <>
            "Normandy 1.0 and 2.0 template has; it cannot be rebuilt (MIGRATING-2.0.md §22)"
  end

  # The same pointer as Toolset's @migration (check_tool!/2), kept as a copy: one string.
  @tools_section "see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour)"

  # Ruling 5: the supplement is where a 1.x tool setup can reach a 2.0 node.
  defp supplement_toolset!(%{tool_registry: _}) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement has :tool_registry, which 2.0 calls " <>
            ":toolset (a %Normandy.Tools.Toolset{} or nil); #{@tools_section}"
  end

  defp supplement_toolset!(%{toolset: nil}), do: nil

  defp supplement_toolset!(%{toolset: %Toolset{} = toolset}) do
    toolset
    |> Toolset.list()
    |> Enum.each(&Toolset.check_tool!(&1, "Normandy.Agents.ConfigTemplate.rebuild/3"))

    toolset
  end

  defp supplement_toolset!(%{toolset: other}) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement's :toolset must be a " <>
            "%Normandy.Tools.Toolset{} or nil, got: #{Describe.type_of(other)}"
  end

  defp supplement_toolset!(_supplement) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement has no :toolset (a " <>
            "%Normandy.Tools.Toolset{} or nil)"
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
                "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(tmpl.template_id)} was saved " <>
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
