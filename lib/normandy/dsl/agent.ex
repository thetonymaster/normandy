defmodule Normandy.DSL.Agent do
  @moduledoc """
  DSL for defining AI agents with a clean, declarative syntax.

  Provides macros to simplify agent creation with sensible defaults and
  expressive configuration options.

  ## Examples

      defmodule MyResearchAgent do
        use Normandy.DSL.Agent

        agent do
          name "Research Agent"
          description "Conducts research and analysis"

          model "claude-opus-5-5"
          max_tokens 16_000

          system_prompt \"\"\"
          You are a helpful research assistant.
          Provide thorough, well-researched answers.
          \"\"\"

          # Optional: Define tools
          tool CalculatorTool
          tool SearchTool
        end
      end

      # Create an instance
      agent = MyResearchAgent.new(client: my_client)

      # Run the agent
      {:ok, updated_agent, response} = MyResearchAgent.run(agent, "Research quantum computing")

  ## Without DSL (for comparison)

      config = %{
        client: my_client,
        model: "claude-opus-5-5",
        max_tokens: 16_000
      }

      agent = Normandy.Agents.BaseAgent.init(config)
      # ... configure system prompt, tools, etc.

  ## Features

  - Clean, declarative syntax
  - Sensible defaults
  - Configuration checked when the agent is built (`new/1` raises without a model)
  - Checked when the module compiles: an `agent` block with `system_prompt` beside
    `background`, `steps` or `output_instructions` raises `ArgumentError`
  - Generated helper functions
  - Tool registration support
  - Memory management helpers
  - `hooks` - lifecycle hook modules (`Normandy.Behaviours.Hooks`), `[{Mod, opts}]`

  ## Name clashes

  `use Normandy.DSL.Agent` imports every macro of this module, `hooks/1` included. A
  module that defines its own `hooks/1` compiles, but an unqualified local call
  `hooks(...)` inside it is a compile error (it matches both the local function and the
  import). Keep the DSL's `hooks` by calling it
  qualified, and drop it from the import:

      defmodule MyAgent do
        use Normandy.DSL.Agent
        import Normandy.DSL.Agent, except: [hooks: 1]

        def hooks(x), do: x

        agent do
          model "claude-opus-5-5"
          Normandy.DSL.Agent.hooks [{MyApp.Hooks.Audit, []}]
        end
      end

  A second `import` of the same module replaces the first, so `use` stays as it is.
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.InitOptions
  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory
  alias Normandy.Options
  alias Normandy.Tools.Memory

  defmacro __using__(_opts) do
    quote do
      import Normandy.DSL.Agent
      Module.register_attribute(__MODULE__, :agent_config, accumulate: false)
      Module.register_attribute(__MODULE__, :agent_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :agent_hooks, accumulate: false)
      @before_compile Normandy.DSL.Agent
    end
  end

  @doc """
  Defines an agent configuration block.

  ## Available Options

  - `name` - Agent name (optional)
  - `description` - Agent description (optional)
  - `model` - LLM model to use (required)
  - `temperature` - Sampling temperature, or omit it to send none (default: none; Opus 4.7+ reject sampling parameters)
  - `max_tokens` - Maximum tokens in response (default: 16_000)
  - `system_prompt` - System prompt text (optional). Not together with `background`,
    `steps` or `output_instructions`: the module does not compile
  - `background` - Background context for prompt (optional)
  - `steps` - Internal reasoning steps (optional)
  - `output_instructions` - Output formatting instructions (optional)
  - `tool` - Register a tool: `tool MyTool` registers `%MyTool{}`, `tool MyTool, timeout: 60_000`
    passes registration options (`Normandy.Tools.Toolset.register/3`); can be called multiple
    times
  - `max_messages` - Maximum messages in memory (optional)

  ## Examples

      agent do
        name "My Agent"
        model "claude-opus-5-5"

        system_prompt "You are helpful."
      end
  """
  defmacro agent(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Sets the agent name.
  """
  defmacro name(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_name, unquote(value))
    end
  end

  @doc """
  Sets the agent description.
  """
  defmacro description(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_description, unquote(value))
    end
  end

  @doc """
  Sets the LLM model.
  """
  defmacro model(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_model, unquote(value))
    end
  end

  @doc """
  Sets the temperature.
  """
  defmacro temperature(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_temperature, unquote(value))
    end
  end

  @doc """
  Sets the max tokens.
  """
  defmacro max_tokens(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_max_tokens, unquote(value))
    end
  end

  @doc """
  Sets the maximum number of tool calls executed concurrently inside a single
  tool-loop iteration. Defaults to `1` (sequential — matches pre-0.5.0
  observable behaviour). Values `> 1` opt the agent into bounded parallel tool
  execution with up to N tools running at once. The final result list passed
  back to the LLM stays in the LLM's tool-call order (`Task.async_stream` is
  invoked with `ordered: true`).

  Streaming callback ordering: `BaseAgent.stream/3` delivers
  `%StreamEvent{type: :tool_result}` from inside each worker as soon as that
  tool finishes. At `max_tool_concurrency > 1`, callers therefore observe
  `:tool_result` events in **completion order**, not LLM-call order — a
  100ms tool that fires after a 500ms tool will still emit its `:tool_result`
  first. If you need LLM-order callback handling, set `max_tool_concurrency:
  1` or buffer events and reorder them yourself after the stream completes.

  Process-semantics note: tool invocations run inside `Task.async_stream`
  workers, even at `max_tool_concurrency: 1`. Streaming callbacks fired *while
  a tool is executing* therefore run in those worker processes — capture
  `parent = self()` outside the callback before sending messages to the
  test/owner process. Streaming callbacks fired outside tool execution (e.g.
  `:text_delta` before any `tool_use`) still run in the caller's process.
  """
  defmacro max_tool_concurrency(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_max_tool_concurrency, unquote(value))
    end
  end

  @doc """
  Sets the system prompt.
  """
  defmacro system_prompt(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_system_prompt, unquote(value))
    end
  end

  @doc """
  Sets the background context.
  """
  defmacro background(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_background, unquote(value))
    end
  end

  @doc """
  Sets the internal steps.
  """
  defmacro steps(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_steps, unquote(value))
    end
  end

  @doc """
  Sets the output instructions.
  """
  defmacro output_instructions(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_output_instructions, unquote(value))
    end
  end

  @doc """
  Registers a tool: `new/1` registers `%module{}` with `opts`
  (`Normandy.Tools.Toolset.register/3`'s options, e.g. `timeout: 60_000`). A tool whose
  struct needs configuration is registered at runtime with `BaseAgent.register_tool/3`.
  """
  defmacro tool(module, opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :agent_tools, {unquote(module), unquote(opts)})
    end
  end

  @store_declared_msg "memory/1 does not take :store; pass the store at runtime with new(memory_store: {module, handle})"

  @doc """
  Declares persistent memory (`Normandy.Tools.Memory`). Takes `Memory.new/1`'s options
  except `:store`, which a handle such as a Redis connection cannot supply at compile
  time: pass `memory_store: {module, handle}` to `new/1`. The namespace comes from
  `tool_context` (`new/1`'s `:tool_context`).
  """
  defmacro memory(opts \\ []) do
    # A literal declaration is rejected at compile time; memory_tool!/3 covers the rest.
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :store),
      do: raise(ArgumentError, @store_declared_msg)

    quote do
      Module.put_attribute(__MODULE__, :agent_memory, unquote(opts))
    end
  end

  @doc """
  Sets the maximum number of messages in memory.
  """
  defmacro max_messages(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_max_messages, unquote(value))
    end
  end

  @doc """
  Configures guardrails for the agent.

  `stage` is either `:input` or `:output`. `specs` is a list of guard
  specifications — either a module atom or `{module, opts}` tuple. See
  `Normandy.Guardrails` for the full contract.

  Calling this macro twice for the same stage replaces the previous list.

  An input violation always fails the run. An output violation blocks the answer
  by default: `run` returns `{:error, %Normandy.Guardrails.ViolationError{}}`
  (`run!` raises it) and the answer is not saved to memory. Pass
  `on_violation: :warn` (output only) to log the violation and return the answer
  instead. Telemetry is emitted either way.
  Streaming output (`stream/3`) reports violations through the
  `:guardrail_violation` stream event and telemetry instead; see `Normandy.Guardrails`.

  ## Example

      agent do
        model "claude-opus-5-5"

        guardrails :input, [
          {Normandy.Guardrails.Builtins.MaxLength, limit: 10_000},
          {Normandy.Guardrails.Builtins.ForbiddenSubstrings, terms: ["ignore previous"]}
        ]

        guardrails :output, [
          {Normandy.Guardrails.Builtins.RegexGuard,
           patterns: [~r/\\b\\d{3}-\\d{2}-\\d{4}\\b/], mode: :deny}
        ]
      end
  """
  defmacro guardrails(stage, specs, opts \\ []) when stage in [:input, :output] do
    attr =
      case stage do
        :input -> :agent_input_guardrails
        :output -> :agent_output_guardrails
      end

    on_violation =
      case {stage, Keyword.fetch(opts, :on_violation)} do
        {_stage, :error} ->
          nil

        {:output, {:ok, value}} ->
          value

        {:input, {:ok, _value}} ->
          raise ArgumentError,
                "guardrails/3: on_violation applies to :output guardrails only " <>
                  "(an input violation always raises)"
      end

    quote do
      Module.put_attribute(__MODULE__, unquote(attr), unquote(specs))

      if unquote(on_violation) do
        Module.put_attribute(
          __MODULE__,
          :agent_output_guardrails_on_violation,
          unquote(on_violation)
        )
      end
    end
  end

  @doc """
  Selects the output-guardrail streaming mode for this agent.

  `:accumulate` (default) runs guards on the full message after the stream
  completes; `:incremental` runs guards at chunk boundaries and halts the
  stream on violation. See `Normandy.Guardrails` for the full semantics.
  """
  defmacro streaming_mode(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_output_guardrails_streaming_mode, unquote(value))
    end
  end

  @doc """
  Sets the chunk size (bytes of accumulated text) at which incremental output
  guardrails run. Only takes effect when `streaming_mode :incremental` is set.
  Default: 200.
  """
  defmacro streaming_chunk_size(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_output_guardrails_chunk_size, unquote(value))
    end
  end

  @doc """
  Declares lifecycle hooks (`Normandy.Behaviours.Hooks`): an ordered list of
  `{module, opts}` entries, once per agent. They run before any `hooks` in a
  `behaviours:` given to `new/1`. A literal list is checked at compile time (shape,
  `:on_error`, plain-data opts); modules and their `validate_opts!/1` are checked when
  `new/1` builds the agent.

      hooks [{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}]
  """
  defmacro hooks(entries) do
    expanded = Macro.prewalk(entries, &Macro.expand(&1, __CALLER__))

    if Macro.quoted_literal?(expanded),
      do: Hooks.validate_entries!(expanded, load: false)

    quote do
      if Module.get_attribute(__MODULE__, :agent_hooks) != nil do
        raise ArgumentError,
              "hooks/1 is declared twice in #{inspect(__MODULE__)}; declare one list"
      end

      Module.put_attribute(__MODULE__, :agent_hooks, unquote(entries))
    end
  end

  # new/1 takes BaseAgent.init/1's options without their defaults (an option left out
  # keeps the agent's declared value; :client is required), plus three of its own.
  @own_options [
    override: [
      type: :keyword_list,
      default: [],
      doc:
        "`BaseAgent.init/1` options except `:client` (and `:max_messages`) that win over the " <>
          "top-level ones."
    ],
    memory_store: [
      type: {:tuple, [:atom, :any]},
      doc:
        "`{module, handle}`: the store for a declared `memory`; required when the agent " <>
          "declares memory, rejected when it does not."
    ],
    max_messages: [
      type: {:or, [:pos_integer, nil]},
      doc: "Caps the memory at this many messages; ignored when `:memory` is given."
    ]
  ]

  @init_definition InitOptions.without_defaults(InitOptions.definition())

  # :client is a top-level option only (1.x rejected it under :override): one source for it.
  @override_definition Keyword.delete(@init_definition, :client) ++
                         Keyword.take(@own_options, [:max_messages])

  @new_definition Keyword.update!(@init_definition, :client, &Keyword.put(&1, :required, true)) ++
                    Keyword.take(@own_options, [:max_messages, :override, :memory_store])

  @new_schema NimbleOptions.new!(@new_definition)
  @override_schema NimbleOptions.new!(@override_definition)

  @doc false
  # The schema of a DSL agent's new/1, for its generated docs.
  @spec new_schema() :: NimbleOptions.t()
  def new_schema, do: @new_schema

  @doc false
  # new/1's options -> {the BaseAgent.init/1 config, the memory store}. Every option is
  # checked here, under new/1's name, before anything is built.
  @spec init_config!(module(), keyword() | map(), map(), map()) :: {map(), term()}
  def init_config!(agent_module, opts, base_config, compile_config) do
    mfa = {agent_module, :new, 1}
    :ok = InitOptions.check_misnamed!(opts, @new_schema, mfa)
    opts = Options.validate!(opts, @new_schema, mfa)
    {explicit, opts} = Keyword.pop!(opts, :override)

    if Keyword.has_key?(explicit, :client) do
      raise ArgumentError,
            "#{inspect(agent_module)}.new/1: :client goes at the top level, not under :override"
    end

    :ok = InitOptions.check_misnamed!(explicit, @override_schema, mfa)
    explicit = Options.validate!(explicit, @override_schema, mfa)
    {memory_store, implicit} = Keyword.pop(opts, :memory_store)

    {max_messages, overrides} =
      implicit
      |> Keyword.merge(explicit)
      |> Keyword.pop(:max_messages, compile_config.max_messages)

    # After every option check (a misspelled :model is named first) and after the merge (a
    # :model given to new/1 serves an agent that declares none).
    if Keyword.get(overrides, :model, base_config.model) == nil do
      raise ArgumentError,
            "#{inspect(agent_module)}.new/1: requires :model (a string), got none"
    end

    config =
      base_config
      |> Map.merge(Map.new(overrides), &merge_override/3)
      |> put_declared_hooks(compile_config.hooks)
      |> put_memory_cap(max_messages)

    {config, memory_store}
  end

  # A :guardrails override changes only the keys it gives; the rest stay as declared.
  defp merge_override(:guardrails, declared, given), do: Keyword.merge(declared, given)
  defp merge_override(_key, _declared, given), do: given

  # BaseAgent.init/1 takes the cap through the memory; a given :memory wins.
  defp put_memory_cap(config, nil), do: config
  defp put_memory_cap(%{memory: _} = config, _cap), do: config
  defp put_memory_cap(config, cap), do: Map.put(config, :memory, AgentMemory.new_memory(cap))

  @doc false
  # Builds the memory tool from the agent's declared options and the runtime store.
  # Returns nil when the agent neither declares memory nor was given a store.
  def memory_tool!(agent_module, declared, store) do
    case {declared, store} do
      {nil, nil} ->
        nil

      {nil, _store} ->
        raise ArgumentError,
              "#{inspect(agent_module)}.new/1: :memory_store was given, but the agent does not declare memory"

      {_opts, nil} ->
        raise ArgumentError,
              "#{inspect(agent_module)} declares memory; pass memory_store: {module, handle} to new/1"

      {opts, store} ->
        if Keyword.has_key?(opts, :store), do: raise(ArgumentError, @store_declared_msg)

        Memory.new([{:store, store} | opts])
    end
  end

  @doc false
  # Declared hooks first, then any given at runtime in `behaviours:`.
  def put_declared_hooks(config, []), do: config

  def put_declared_hooks(config, declared) do
    behaviours = Map.get(config, :behaviours) || %Normandy.Behaviours.Config{}
    Map.put(config, :behaviours, %{behaviours | hooks: declared ++ behaviours.hooks})
  end

  # The agent block's own contradictions, checked when the module compiles.
  defp check_declarations!(module) do
    structured =
      Enum.filter(
        [
          background: :agent_background,
          steps: :agent_steps,
          output_instructions: :agent_output_instructions
        ],
        fn {_name, attr} -> Module.get_attribute(module, attr) != nil end
      )

    if Module.get_attribute(module, :agent_system_prompt) != nil and structured != [] do
      raise ArgumentError,
            "#{inspect(module)}: system_prompt cannot be combined with " <>
              Enum.map_join(structured, ", ", fn {name, _attr} -> Atom.to_string(name) end) <>
              "; use system_prompt alone or background/steps/output_instructions"
    end

    :ok
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(env) do
    check_declarations!(env.module)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      # Store configuration at compile time - MUST come first before any function uses it
      @agent_compile_config %{
        model: Module.get_attribute(__MODULE__, :agent_model),
        temperature: Module.get_attribute(__MODULE__, :agent_temperature),
        max_tokens:
          Module.get_attribute(
            __MODULE__,
            :agent_max_tokens,
            Normandy.Agents.BaseAgentConfig.default_max_tokens()
          ),
        max_tool_concurrency:
          Normandy.Agents.BaseAgent.normalize_max_tool_concurrency(
            Module.get_attribute(__MODULE__, :agent_max_tool_concurrency, 1)
          ),
        max_messages: Module.get_attribute(__MODULE__, :agent_max_messages),
        system_prompt: Module.get_attribute(__MODULE__, :agent_system_prompt),
        background: Module.get_attribute(__MODULE__, :agent_background),
        steps: Module.get_attribute(__MODULE__, :agent_steps),
        output_instructions: Module.get_attribute(__MODULE__, :agent_output_instructions),
        tools: Module.get_attribute(__MODULE__, :agent_tools, []) |> Enum.reverse(),
        memory: Module.get_attribute(__MODULE__, :agent_memory),
        hooks: Module.get_attribute(__MODULE__, :agent_hooks) || [],
        guardrails: [
          input: Module.get_attribute(__MODULE__, :agent_input_guardrails, []),
          output: Module.get_attribute(__MODULE__, :agent_output_guardrails, []),
          streaming_mode:
            Module.get_attribute(__MODULE__, :agent_output_guardrails_streaming_mode, :accumulate),
          chunk_size: Module.get_attribute(__MODULE__, :agent_output_guardrails_chunk_size, 200),
          on_violation:
            Module.get_attribute(__MODULE__, :agent_output_guardrails_on_violation, :block)
        ]
      }

      # Store additional config at compile time
      @agent_name Module.get_attribute(__MODULE__, :agent_name)
      @agent_description Module.get_attribute(__MODULE__, :agent_description)

      @doc """
      Builds the agent: a `%Normandy.Agents.BaseAgentConfig{}` with the declared
      prompt, tools and memory.

      Takes `BaseAgent.init/1`'s options, which override what the agent declares,
      either at the top level or under `:override` (which wins when both give one).
      Every option is checked first: an unknown option or a bad value raises
      `ArgumentError` naming `#{inspect(__MODULE__)}.new/1` and the option.

          agent = #{inspect(__MODULE__)}.new(client: my_client)
          agent = #{inspect(__MODULE__)}.new(client: my_client, override: [max_tokens: 2048])

      ## Options

      #{Normandy.Options.docs(Normandy.DSL.Agent.new_schema())}
      """
      def new(opts) do
        {config, memory_store} =
          Normandy.DSL.Agent.init_config!(__MODULE__, opts, base_config(), @agent_compile_config)

        # Built before init/1 so a missing store raises before any process starts.
        memory_tool =
          Normandy.DSL.Agent.memory_tool!(__MODULE__, @agent_compile_config.memory, memory_store)

        agent =
          config
          |> BaseAgent.init()
          |> apply_system_prompt()
          |> register_tools()

        if memory_tool, do: BaseAgent.register_tool(agent, memory_tool), else: agent
      end

      @doc """
      Runs the agent with input; see `Normandy.Agents.BaseAgent.run/3`.

      ## Examples

          {:ok, agent, response} = MyAgent.run(agent, "Hello!")
          {:ok, agent, response} = MyAgent.run(agent, %{chat_message: "Hello!"})
      """
      def run(agent, input, opts \\ []) when is_list(opts),
        do: BaseAgent.run(agent, prepare_input(input), opts)

      @doc "Like `run/3`, but returns `{agent, response}` and raises on failure."
      def run!(agent, input, opts \\ []) when is_list(opts),
        do: BaseAgent.run!(agent, prepare_input(input), opts)

      @doc "Streams a turn; see `Normandy.Agents.BaseAgent.stream/3`."
      def stream(agent, input, callback) when is_function(callback, 1),
        do: BaseAgent.stream(agent, prepare_input(input), callback)

      @doc """
      Resets the agent's memory.

      ## Examples

          agent = MyAgent.reset_memory(agent)
      """
      def reset_memory(agent) do
        BaseAgent.reset_memory(agent)
      end

      @doc """
      Returns the agent configuration used by this module.
      """
      def config do
        %{
          name: @agent_name,
          description: @agent_description,
          model: @agent_compile_config.model,
          temperature: @agent_compile_config.temperature,
          max_tokens: @agent_compile_config.max_tokens,
          max_tool_concurrency: @agent_compile_config.max_tool_concurrency,
          system_prompt: @agent_compile_config.system_prompt,
          background: @agent_compile_config.background,
          steps: @agent_compile_config.steps,
          output_instructions: @agent_compile_config.output_instructions,
          tools: @agent_compile_config.tools,
          hooks: @agent_compile_config.hooks,
          max_messages: @agent_compile_config.max_messages,
          guardrails: @agent_compile_config.guardrails
        }
      end

      # Private functions

      defp base_config do
        %{
          model: @agent_compile_config.model,
          temperature: @agent_compile_config.temperature,
          max_tokens: @agent_compile_config.max_tokens,
          max_tool_concurrency: @agent_compile_config.max_tool_concurrency,
          name: @agent_name,
          guardrails: @agent_compile_config.guardrails
        }
      end

      defp apply_system_prompt(agent) do
        case Normandy.DSL.Agent.__prompt_specification__(@agent_compile_config) do
          nil -> agent
          prompt_spec -> %{agent | prompt_specification: prompt_spec}
        end
      end

      defp register_tools(agent) do
        Enum.reduce(@agent_compile_config.tools, agent, fn {tool_module, opts}, acc ->
          BaseAgent.register_tool(acc, struct!(tool_module), opts)
        end)
      end

      defp prepare_input(input) when is_binary(input), do: %{chat_message: input}
      defp prepare_input(input) when is_map(input), do: input
      defp prepare_input(input) when is_list(input), do: input
      defp prepare_input(input), do: %{chat_message: to_string(input)}
    end
  end

  @doc false
  # Called from generated code. Lives here, not in the user's module, so the
  # generated module carries no helper clause the type checker can find unused,
  # and no comparison it can prove constant from the compile-time config.
  @spec __prompt_specification__(map()) :: Normandy.Components.PromptSpecification.t() | nil
  def __prompt_specification__(config) do
    system_prompt = prompt_list(config.system_prompt)
    background = prompt_list(config.background)
    steps = prompt_list(config.steps)
    output_instructions = prompt_list(config.output_instructions)

    cond do
      system_prompt != [] ->
        %Normandy.Components.PromptSpecification{
          background: system_prompt,
          steps: [],
          output_instructions: []
        }

      background != [] or steps != [] or output_instructions != [] ->
        %Normandy.Components.PromptSpecification{
          background: background,
          steps: steps,
          output_instructions: output_instructions
        }

      true ->
        nil
    end
  end

  defp prompt_list(nil), do: []
  defp prompt_list(str) when is_binary(str), do: [str]
  defp prompt_list(list) when is_list(list), do: list
end
