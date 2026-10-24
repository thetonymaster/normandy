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

  ## Trust boundary

  The session store is as trusted as your code. Whoever can write it (a shared Redis, a
  Postgres role another service uses) decides, on the next rehydrate on any node:

    * the policy, budget, compactor and model catalog modules and their opts, the
      guardrails and the hooks (removing them, or `PolicyEngine.AllowAll`);
    * the credential provider and its opts (`Turn.Server` calls it to get a token);
    * `tool_context`, so another tenant's memory namespace;
    * `template_id`, so which node-local supplement, and so which toolset, is used;
    * the saved server options (`on_approval_timeout`, the timeouts);
    * the turn state, including the input of a call parked for approval, and the
      conversation history.

  Keep the store single-tenant, or give Normandy's role its own database or ACL'd key
  prefix. Postgres and Redis decode stored bytes with `binary_to_term(_, [:safe])`, which
  still builds local functions.

  Normandy checks what it can without keys. `check_loaded!/1` runs on every template
  `Turn.Server` loads, before anything in it is used, and in `rebuild/3`: it refuses a
  function, pid, reference or port anywhere in the template, a behaviour ref whose module
  does not implement its behaviour (`policy` a `Normandy.Behaviours.PolicyEngine`,
  `budget` a `BudgetTracker`, `credential` a `CredentialProvider`, `compactor` a
  `Compactor`, `model_catalog` a `ModelCatalog`) and a guard module that does not
  implement `Normandy.Guardrails.Guard`. A supplement's `:pinned` fixes security settings
  on the node: with `pinned: [policy: ref, guardrails: g, credential: ref]` a template
  whose `policy`, `guardrails` or `credential` differs raises, before the credential
  provider is called. `:pinned` takes `:policy`, `:budget`, `:credential`, `:compactor`,
  `:model_catalog`, `:hooks` and `:guardrails`; `tool_context`, `template_id`, turn
  state and history cannot be pinned. Templates are not signed (a known limit).
  """
  alias Normandy.Agents.BaseAgent.InitOptions
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Schema.LegacyMeta
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

  @doc """
  Builds the plain-data template of `config`, to store under `template_id`.

  The template holds the fields the moduledoc lists and a `resume_policy` of `:lazy`; use
  `from_config/3` for `:eager`. Fields that cannot be stored (the client, the toolset,
  `mcp_servers`) are left out, and `node_local_fields` records that `mcp_servers` was set.
  Raises `ArgumentError` when one of `initial_memory`, `retry`, `circuit_breaker`,
  `enable_json_retry`, `json_retry_max_attempts`, `guardrails`, `tool_context` or
  `max_tool_result_chars`, or the opts of a hook entry, holds a function, pid, reference or
  port, or when a hook entry is malformed.
  """
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
  # are not plain data, as storable_fields!/1 does for the fields above.
  defp storable_hooks!(hooks) do
    :ok = Hooks.validate_entries!(hooks, load: false)
    hooks
  end

  # A function, pid, reference or port would be persisted as a term that only works on
  # this node and this code version, so refuse it here; check_loaded!/1 refuses it on load.
  defp storable_fields!(c) do
    fields = Map.take(Map.from_struct(c), @data_fields)

    Enum.each(fields, fn {key, value} ->
      unless Hooks.plain_data?(value) do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.from_config/2: #{inspect(key)} contains a function, " <>
                "pid, reference or port, which a template cannot store. Keep it to plain data " <>
                "(modules, atoms, numbers, strings, lists, maps)."
      end
    end)

    Map.update!(fields, :initial_memory, &memory_cache(&1, :drop))
  end

  # A memory's per-entry encodings (AgentMemory.Entry's `wire` and `tokens`) are derived:
  # a template stores the memory without them, and rebuild/3 computes them again, so a
  # template never replays an encoding made by another Normandy version.
  defp memory_cache(%AgentMemory{} = memory, :drop), do: AgentMemory.drop_cache(memory)
  defp memory_cache(%AgentMemory{} = memory, :fill), do: AgentMemory.fill_cache(memory)
  defp memory_cache(other, _action), do: other

  @doc """
  Builds the template of `config` as `from_config/2` does, with `resume_policy` set to
  `:lazy` or `:eager`.

  `:eager` makes a `Turn.Server` that loads the template resume an in-flight turn as soon as
  it starts; `:lazy` waits for the next call. Raises as `from_config/2` does.
  """
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
    :ok = check_loaded!(tmpl)
    tmpl = tmpl |> LegacyMeta.strip() |> translate!()
    :ok = pinned!(tmpl, supplement)
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
    |> Map.update!(:initial_memory, &memory_cache(&1, :fill))
    |> struct(node_local_fields!(tmpl, supplement))
    |> InitOptions.validate_compaction_config!({__MODULE__, :rebuild, 3})
    |> validate_client_options!()
    |> tap(&InitOptions.warn_deprecated_catalog(&1.behaviours))
  end

  @refs_behaviours [
    policy: Normandy.Behaviours.PolicyEngine,
    budget: Normandy.Behaviours.BudgetTracker,
    credential: Normandy.Behaviours.CredentialProvider,
    compactor: Normandy.Behaviours.Compactor,
    model_catalog: Normandy.Behaviours.ModelCatalog
  ]

  @pinnable [:policy, :budget, :credential, :compactor, :model_catalog, :hooks, :guardrails]

  @doc """
  Checks a template read from a session store before anything in it is used (see "Trust
  boundary"). `Turn.Server` calls it on every template it loads, and `rebuild/3` calls it
  first.

  Raises `ArgumentError` naming the field for a function, pid, reference or port anywhere
  in the template, a `behaviours_refs` slot that is not `{module, keyword}` or whose module
  is not loaded on this node or does not implement the slot's behaviour, and a guard in
  `guardrails` whose module does not implement `Normandy.Guardrails.Guard`. A missing or
  unknown field or slot is left to `rebuild/3`, which names it. Values are never shown.
  """
  @spec check_loaded!(map()) :: :ok
  def check_loaded!(tmpl) when is_map(tmpl) do
    id = Map.get(tmpl, :template_id)

    case Enum.find(Enum.sort(tmpl), fn {_key, value} -> not Hooks.plain_data?(value) end) do
      nil -> :ok
      {key, _} -> refused!(id, "#{inspect(key)} holds a function, pid, reference or port")
    end

    :ok = check_refs!(Map.get(tmpl, :behaviours_refs), id)
    check_guards!(Map.get(tmpl, :guardrails, []), id)
  end

  def check_loaded!(other) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.check_loaded!/1: expected a template map, got: " <>
            Describe.type_of(other)
  end

  defp check_refs!(refs, id) when is_map(refs) do
    Enum.each(@refs_behaviours, fn {slot, behaviour} ->
      case Map.fetch(refs, slot) do
        :error -> :ok
        {:ok, ref} -> check_ref!(slot, ref, behaviour, id)
      end
    end)
  end

  # Not a map: translate!/1 names it.
  defp check_refs!(_refs, _id), do: :ok

  # 1.x's default credential provider, removed in 2.0: a template saved by 1.x names it.
  defp check_ref!(:credential, {Normandy.Behaviours.CredentialProvider.FromClient, _opts}, _b, id) do
    refused!(
      id,
      "behaviours_refs :credential names Normandy.Behaviours.CredentialProvider.FromClient, " <>
        "which was removed in 2.0; set the config's behaviours :credential to a " <>
        "Normandy.Behaviours.CredentialProvider module ({module, opts}) and save the " <>
        "template again"
    )
  end

  defp check_ref!(slot, {mod, opts}, behaviour, id) when is_atom(mod) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: bad_ref!(slot, behaviour, id, "opts that are not a keyword list")

    unless implements?(mod, behaviour),
      do: bad_ref!(slot, behaviour, id, inspect(mod))

    :ok
  end

  defp check_ref!(slot, other, behaviour, id),
    do: bad_ref!(slot, behaviour, id, Describe.type_of(other))

  @spec bad_ref!(atom(), module(), term(), String.t()) :: no_return()
  defp bad_ref!(slot, behaviour, id, got) do
    refused!(
      id,
      "behaviours_refs #{inspect(slot)} must be {module, keyword} whose module is loaded on " <>
        "this node and implements #{inspect(behaviour)}, got: #{got}"
    )
  end

  defp check_guards!(guardrails, id) when is_list(guardrails) do
    for stage <- [:input, :output],
        {^stage, specs} <- guardrails,
        spec <- List.wrap(specs) do
      check_guard!(stage, spec, id)
    end

    :ok
  end

  defp check_guards!(other, id),
    do: refused!(id, ":guardrails must be a keyword list, got: #{Describe.type_of(other)}")

  defp check_guard!(stage, {mod, opts}, id) when is_atom(mod) and is_list(opts),
    do: check_guard!(stage, mod, id)

  defp check_guard!(stage, mod, id) when is_atom(mod) do
    unless implements?(mod, Normandy.Guardrails.Guard),
      do:
        refused!(
          id,
          ":guardrails #{inspect(stage)} guard #{inspect(mod)} is not loaded on this node or " <>
            "does not implement Normandy.Guardrails.Guard"
        )

    :ok
  end

  defp check_guard!(stage, other, id) do
    refused!(
      id,
      ":guardrails #{inspect(stage)} has a guard that is not a module or {module, opts}: " <>
        Describe.type_of(other)
    )
  end

  defp implements?(mod, behaviour) do
    Code.ensure_loaded?(mod) and
      behaviour in (mod.module_info(:attributes)
                    |> Keyword.get_values(:behaviour)
                    |> List.flatten())
  end

  @spec refused!(term(), String.t()) :: no_return()
  defp refused!(id, what) do
    raise ArgumentError,
          "Normandy.Agents.ConfigTemplate.check_loaded!/1: template #{inspect(id)} #{what}; " <>
            "it is not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
  end

  @doc false
  # The template's shape as rebuild/3 reads it (required fields and behaviours_refs slots,
  # a map of refs), checked by Turn.Server right after check_loaded!/1 and before it reads
  # :template_id or the credential ref. Raises ArgumentError naming the field or slot.
  @spec check_translatable!(map()) :: :ok
  def check_translatable!(tmpl) do
    _ = translate!(tmpl)
    :ok
  end

  @doc false
  # The supplement's :pinned against a template as stored: Turn.Server checks it before it
  # calls the template's credential provider, rebuild/3 again after translation.
  @spec check_pinned!(map(), map()) :: :ok
  def check_pinned!(tmpl, supplement), do: tmpl |> translate!() |> pinned!(supplement)

  defp pinned!(tmpl, supplement) do
    pinned = Map.get(supplement, :pinned, [])

    unless Keyword.keyword?(pinned) do
      raise ArgumentError,
            "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement's :pinned must be a " <>
              "keyword list, got: #{Describe.type_of(pinned)}"
    end

    Enum.each(pinned, fn {field, expected} ->
      unless field in @pinnable do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement pins #{inspect(field)}; " <>
                ":pinned takes #{Enum.map_join(@pinnable, ", ", &inspect/1)}"
      end

      if pinned_value(tmpl, field) != expected do
        raise ArgumentError,
              "Normandy.Agents.ConfigTemplate.rebuild/3: template #{inspect(tmpl.template_id)} " <>
                "has a #{inspect(field)} that differs from the one this node's supplement pins; " <>
                "it is not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
      end
    end)
  end

  defp pinned_value(tmpl, :guardrails),
    do: Map.get(tmpl, :guardrails, BaseAgentConfig.default_guardrails())

  defp pinned_value(tmpl, :hooks), do: Map.get(tmpl.behaviours_refs, :hooks, [])
  defp pinned_value(tmpl, slot), do: Map.fetch!(tmpl.behaviours_refs, slot)

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
        {Compactor.WindowManager, strategy!(opts)}

      {{:ok, _window}, true} ->
        untranslatable!(
          id,
          "has Compactor.WindowManager opts with both :max_tokens (1.0) and :context_window (2.0)"
        )

      {{:ok, window}, false} ->
        {Compactor.WindowManager,
         opts
         |> Keyword.delete(:max_tokens)
         |> Keyword.put(:context_window, window)
         |> strategy!()}
    end
  end

  defp compactor_ref!(ref, _id), do: ref

  # 1.0 and 2.0 builds before :sliding_window was removed took it as an alias of
  # :oldest_first. The atom stays named here: Postgres and Redis decode a stored template
  # with binary_to_term(_, [:safe]), which refuses an atom nothing in the code names.
  defp strategy!(opts) do
    case Keyword.fetch(opts, :strategy) do
      {:ok, :sliding_window} -> Keyword.put(opts, :strategy, :oldest_first)
      _other -> opts
    end
  end

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
    _ = InitOptions.validate_client_options!(client)
    config
  end
end
