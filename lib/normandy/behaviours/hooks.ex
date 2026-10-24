defmodule Normandy.Behaviours.Hooks do
  @moduledoc """
  Lifecycle hooks: modules an agent lists on `Normandy.Behaviours.Config` `:hooks` as
  `{module, opts}` entries, run in list order.

  Every callback is optional; an entry whose module does not export an event's callback is
  skipped for that event. A hook exists where it can change an outcome (rewrite, halt,
  inject) or must run application code in-process; to only observe, attach to telemetry.
  Hooks run inline, with no timeout: a slow hook stalls its turn, so hand slow side effects
  to a process of your own.

  `use Normandy.Behaviours.Hooks` sets `@behaviour` and checks at compile time that a
  public function named like an event has that event's arity (`ArgumentError` otherwise),
  and warns for a public function whose name is close to an event's (`on_promt`).

  Return values, checked only where the library consumes them:

  | Callback | Pass | Change | Stop |
  |---|---|---|---|
  | `on_prompt/3` | `{:cont, input}` | `{:cont, new_input}` | `{:halt, reason}` |
  | `before_llm/3` | `:cont` | — | `{:halt, reason}` |
  | `before_tool/3` | `{:cont, call}` | `{:cont, new_call}` | `{:halt, reason}` or `{:halt, %ToolResult{}}` |
  | `after_tool/4` | `{:cont, result}` | `{:cont, new_result}` | — |
  | `after_compact/4`, `on_session_start/2` | any value | `{:inject, [String.t()]}` | — |
  | `on_turn_end/3`, `on_passivate/2` | any value (ignored) | — | — |

  `on_turn_end/3` receives `{:ok, response}`, `{:rejected, exception}` (a schema,
  input-guardrail or output-guardrail rejection, or an `on_prompt` halt) or
  `{:error, exception}`. The shells differ only for a failure that is not Normandy's own:
  under `BaseAgent` a raised exception (a crashing client's `RuntimeError`) arrives bare
  and an exit or throw as a `:task_down` `Normandy.TurnError`; under `Turn.Server` each
  arrives as the `Normandy.TurnError` that `run/2` replies (`:task_down` or
  `:handler_crashed`).

  `opts` must be plain data (no function, pid, reference or port) and hold no secrets: the
  list is saved in the session's plaintext config template. `:on_error` (`:reraise`
  default, `:open`, `:closed`) is reserved and removed before a callback sees `opts`. See
  `docs/guides/hooks.md`.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context

  @events [
    on_session_start: 2,
    on_passivate: 2,
    on_prompt: 3,
    before_llm: 3,
    before_tool: 3,
    after_tool: 4,
    after_compact: 4,
    on_turn_end: 3
  ]

  @on_error [:reraise, :open, :closed]

  @type opts :: keyword()
  @type entry :: {module(), opts()}
  @type outcome ::
          {:ok, response :: term()} | {:error, Exception.t()} | {:rejected, Exception.t()}

  @doc """
  Runs when `Turn.Server` starts a session whose store holds no history, once per start.

  Return `{:inject, [text]}` to add each text to the conversation as a user message; the
  texts are stored and survive a restart. `{:inject, texts}` with anything but a list of
  strings raises `ArgumentError`, whatever `:on_error` says; any other return value is
  ignored. A crash is handled by the entry's `:on_error`; under `:reraise` the session waits `:unavailable` and
  retries the start.
  """
  @callback on_session_start(Context.t(), opts()) :: {:inject, [String.t()]} | term()
  @doc """
  Runs in `Turn.Server` before an idle session stops.

  The return value is ignored. A crash is logged, whatever `:on_error` says.
  """
  @callback on_passivate(Context.t(), opts()) :: term()
  @doc """
  Runs on a turn's validated input, before input guardrails.

  Return `{:cont, input}` to pass on the input, changed or not; a changed input is validated
  again. Return `{:halt, reason}` to end the turn with a `Normandy.HookHaltError` before any
  model call. Any other return value raises `ArgumentError`.
  """
  @callback on_prompt(input :: term(), Context.t(), opts()) ::
              {:cont, term()} | {:halt, reason :: String.t()}
  @doc """
  Runs before each model call, with `%{final: boolean, iterations_left: integer}`.

  Return `:cont` to make the call, or `{:halt, reason}` to end the turn with a
  `Normandy.HookHaltError` without making it. A halt is not retried. Any other return value
  raises `ArgumentError`.
  """
  @callback before_llm(%{final: boolean(), iterations_left: integer()}, Context.t(), opts()) ::
              :cont | {:halt, reason :: String.t()}
  @doc """
  Runs before each tool call, with the model's `Normandy.Components.ToolCall`.

  Return `{:cont, call}` to run the tool with the call, changed or not. Return
  `{:halt, reason}` or `{:halt, %Normandy.Components.ToolResult{}}` to skip the tool: the
  result, or an error result carrying `reason`, answers the call. A halt ends only this
  call, not the turn. Any other return value raises `ArgumentError`.
  """
  @callback before_tool(ToolCall.t(), Context.t(), opts()) ::
              {:cont, ToolCall.t()} | {:halt, String.t() | ToolResult.t()}
  @doc """
  Runs on every tool result the model will see, once, with the call and its
  `Normandy.Components.ToolResult`.

  Return `{:cont, result}` with the result to send, changed or not. That includes the error
  results of a denied, halted or failed call. Any other return value raises `ArgumentError`.
  """
  @callback after_tool(ToolCall.t(), ToolResult.t(), Context.t(), opts()) ::
              {:cont, ToolResult.t()}
  @doc """
  Runs after a compaction that removed messages, with `dropped`, the removed
  `Normandy.Components.AgentMemory.Entry` structs (oldest first), and `meta`, the
  compactor's metadata without `:dropped`.

  Return `{:inject, [text]}` to append each text to the conversation as a user message
  before the next model call. `{:inject, texts}` with anything but a list of strings raises
  `ArgumentError`, whatever `:on_error` says; any other return value is ignored. Under
  `Turn.Server` the compacted conversation, with the injected texts, is stored, so a restart
  does not report the same messages again; if that write failed they are reported again under
  the same entry ids, so deduplicate on `entry.id`.
  """
  @callback after_compact(dropped :: [Entry.t()], meta :: map(), Context.t(), opts()) ::
              {:inject, [String.t()]} | term()
  @doc """
  Runs at the end of a turn, with `{:ok, response}`, `{:rejected, exception}` or
  `{:error, exception}`.

  `Turn.Server` runs it after it has replied to `run/2`; `BaseAgent.run/3` runs it before it
  returns.

  The return value is ignored. A crash is logged, whatever `:on_error` says.
  """
  @callback on_turn_end(outcome(), Context.t(), opts()) :: term()
  @doc """
  Optional: checks the entry's `opts` (without `:on_error`) when hook entries are validated,
  in `BaseAgent.init/1` and when `Turn.Server` loads a session.

  Raise on a bad option; any exception is re-raised as an `ArgumentError` that names the
  hook module. The return value is ignored.
  """
  @callback validate_opts!(opts()) :: term()

  @optional_callbacks @events ++ [validate_opts!: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour Normandy.Behaviours.Hooks
      @before_compile Normandy.Behaviours.Hooks
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    for warning <- check_definitions!(Module.definitions_in(env.module, :def)) do
      IO.warn(warning, Macro.Env.stacktrace(env))
    end

    nil
  end

  @doc "The event callbacks, as `{name, arity}`."
  @spec events() :: [{atom(), non_neg_integer()}]
  def events, do: @events

  @doc false
  # Compile-time check for `use`: raises for a public function named like an event with
  # another arity; returns a warning for each public function whose name is close to an
  # event's. A misspelled callback is skipped at runtime, silently.
  @spec check_definitions!([{atom(), non_neg_integer()}]) :: [String.t()]
  def check_definitions!(definitions) do
    Enum.each(definitions, fn {name, arity} -> check_definition_arity!(name, arity) end)

    definitions
    |> Enum.flat_map(fn {name, _arity} -> near_miss(name) end)
    |> Enum.uniq()
  end

  defp check_definition_arity!(name, arity) do
    case Keyword.fetch(@events, name) do
      {:ok, ^arity} ->
        :ok

      {:ok, expected} ->
        raise ArgumentError,
              "#{name}/#{arity} is not a hook callback: #{name} takes #{expected} arguments"

      :error ->
        :ok
    end
  end

  defp near_miss(name) do
    if Keyword.has_key?(@events, name) or name == :validate_opts! do
      []
    else
      text = Atom.to_string(name)

      for {event, _arity} <- @events,
          String.jaro_distance(text, Atom.to_string(event)) >= 0.9,
          do:
            "#{name} is not a hook callback; did you mean #{event}? A misspelled callback never runs"
    end
  end

  @doc """
  Raises `ArgumentError` naming the first malformed entry. With `load: false` (DSL compile
  time and `ConfigTemplate.from_config/2`, where the module may not be loaded) only the
  entry shape, `:on_error` and the plain-data rule are checked.
  """
  @spec validate_entries!(term(), keyword()) :: :ok
  def validate_entries!(entries, opts \\ [])

  def validate_entries!(entries, opts) when is_list(entries) do
    load? = Keyword.get(opts, :load, true)
    Enum.each(entries, &validate_entry!(&1, load?))
  end

  def validate_entries!(other, _opts) do
    raise ArgumentError,
          "hooks must be a list of {module, opts} entries, got: #{inspect(other)}"
  end

  @doc """
  `validate_entries!/1` as data, for `Turn.Server`: an invalid list (a hook module missing
  on this node, say) is reported like a store fault instead of crashing the start.
  """
  @spec check_entries(term()) :: :ok | {:error, {:invalid_hooks, String.t()}}
  def check_entries(entries) do
    validate_entries!(entries)
  rescue
    # Every validation failure is an ArgumentError, including a failing `validate_opts!/1`
    # (re-raised as one); anything else is a bug and must crash.
    e in ArgumentError -> {:error, {:invalid_hooks, Exception.message(e)}}
  end

  defp validate_entry!({mod, opts} = entry, load?) when is_atom(mod) and is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_entry!(entry)
    validate_on_error!(mod, Keyword.get(opts, :on_error, :reraise))

    unless plain_data?(opts) do
      raise ArgumentError,
            "hook opts for #{inspect(mod)} must be plain data: they are saved in the " <>
              "session's config template. Found a function, pid, reference or port; name a " <>
              "registered process instead of passing a pid, and read secrets at call time."
    end

    if load?, do: validate_module!(mod, Keyword.delete(opts, :on_error))
    :ok
  end

  defp validate_entry!(entry, _load?), do: invalid_entry!(entry)

  @spec invalid_entry!(term()) :: no_return()
  defp invalid_entry!(entry) do
    raise ArgumentError,
          "invalid hook entry #{inspect(entry)}: expected {module, keyword_opts}"
  end

  defp validate_on_error!(_mod, policy) when policy in @on_error, do: :ok

  defp validate_on_error!(mod, other) do
    raise ArgumentError,
          "invalid :on_error for #{inspect(mod)}: expected :reraise, :open or :closed, " <>
            "got: #{inspect(other)}"
  end

  defp validate_module!(mod, opts) do
    unless Code.ensure_loaded?(mod) do
      raise ArgumentError, "hook module #{inspect(mod)} is not available"
    end

    exports = mod.module_info(:exports)
    Enum.each(@events, fn {event, arity} -> check_export_arity!(mod, exports, event, arity) end)

    unless Enum.any?(@events, &(&1 in exports)) do
      raise ArgumentError,
            "hook module #{inspect(mod)} exports none of the hook callbacks " <>
              Enum.map_join(@events, ", ", fn {f, a} -> "#{f}/#{a}" end)
    end

    if {:validate_opts!, 1} in exports, do: run_validate_opts!(mod, opts)
    :ok
  end

  # A module without `use` gets this check here instead of at compile time.
  defp check_export_arity!(mod, exports, event, arity) do
    case for({^event, other} <- exports, other != arity, do: other) do
      [] ->
        :ok

      [other | _] ->
        unless {event, arity} in exports do
          raise ArgumentError,
                "hook module #{inspect(mod)} exports #{event}/#{other}, but the hook " <>
                  "callback is #{event}/#{arity}"
        end
    end
  end

  defp run_validate_opts!(mod, opts) do
    mod.validate_opts!(opts)
  rescue
    e ->
      reraise ArgumentError,
              "invalid opts for hook #{inspect(mod)}: #{Exception.message(e)}",
              __STACKTRACE__
  end

  @doc false
  # Plain data: no function, pid, reference or port anywhere inside. A stored template's
  # rule too (Normandy.Agents.ConfigTemplate).
  @spec plain_data?(term()) :: boolean()
  def plain_data?(value)
      when is_function(value) or is_pid(value) or is_reference(value) or is_port(value),
      do: false

  def plain_data?([head | tail]), do: plain_data?(head) and plain_data?(tail)
  def plain_data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> plain_data?()
  def plain_data?(%_{} = value), do: value |> Map.from_struct() |> plain_data?()

  def plain_data?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> plain_data?(k) and plain_data?(v) end)

  def plain_data?(_value), do: true
end
