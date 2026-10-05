defmodule Normandy.Hooks.Runner do
  @moduledoc """
  The only caller of hook modules (`Normandy.Behaviours.Hooks`). Every function takes the
  agent's config, reads its entries (`config.behaviours.hooks`) and runs, in list order,
  the entries whose module exports the event's callback. With none it returns the pass
  value at once: no context is built and no telemetry is emitted.

  These functions are also the supported way to test a hook with the library's rules
  applied (rewrite threading, halts, `:on_error`, return contracts): pass a config map such
  as `%{name: "a", behaviours: %{hooks: [{MyHook, []}]}}`.

  ## Rules

    * A rewrite (`{:cont, new}`) is what the next entry receives; the first halt stops the
      chain.
    * `:on_error`, removed from opts before the callback sees them:

      | Event | `:reraise` (default) | `:open` | `:closed` |
      |---|---|---|---|
      | `on_prompt`, `before_llm`, `before_tool` | propagates | logged; the value passes on | halts, reason naming the hook |
      | `after_tool` | propagates | logged; the result passes on | the result becomes an error result naming the hook; later `after_tool` entries do not run |
      | `after_compact`, `on_session_start` | propagates | logged; injects nothing | propagates |
      | `on_turn_end`, `on_passivate` | logged | logged | logged |

    * A return value is checked only where the library consumes it; a violation raises
      `ArgumentError` whatever `:on_error` says. `on_turn_end` and `on_passivate` ignore
      their return value, and so do `after_compact`/`on_session_start` for anything but
      `{:inject, texts}`.
    * A module that is not loaded raises `ArgumentError` (logged and skipped on
      `on_turn_end`/`on_passivate`). `handles?/2` is a plain predicate: such a module is
      simply not handling.
    * Each entry call is a `[:normandy, :hook, :start | :stop | :exception]` span.
  """

  require Logger

  alias Normandy.Behaviours.Hooks
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.Context
  alias Normandy.Telemetry.Span
  alias Normandy.TurnError

  @arity Map.new(Hooks.events())
  @logged_only [:on_turn_end, :on_passivate]
  @closable [:on_prompt, :before_llm, :before_tool, :after_tool]
  @injecting [:after_compact, :on_session_start]

  @contracts %{
    on_prompt: "{:cont, input} or {:halt, reason :: String.t()}",
    before_llm: ":cont or {:halt, reason :: String.t()}",
    before_tool: "{:cont, %ToolCall{}} or {:halt, reason :: String.t() | %ToolResult{}}",
    after_tool: "{:cont, %ToolResult{}}",
    after_compact: "{:inject, [String.t()]} or any other value (ignored)",
    on_session_start: "{:inject, [String.t()]} or any other value (ignored)",
    on_passivate: "any value (ignored)",
    on_turn_end: "any value (ignored)"
  }

  @doc "The agent's hook entries: `config.behaviours.hooks`, or `[]`."
  @spec entries(map() | nil) :: [Hooks.entry()]
  def entries(%{behaviours: %{hooks: hooks}}) when is_list(hooks), do: hooks
  def entries(_config), do: []

  @doc "Whether the agent has any hook entry."
  @spec hooks?(map() | nil) :: boolean()
  def hooks?(config), do: entries(config) != []

  @doc """
  Whether any entry's module exports `event`'s callback. A module that is not loaded does
  not handle anything: no log, no raise (the call-time functions deal with it).
  """
  @spec handles?(map() | nil, atom()) :: boolean()
  def handles?(config, event) do
    arity = Map.fetch!(@arity, event)

    Enum.any?(entries(config), fn {mod, _opts} ->
      Code.ensure_loaded?(mod) and function_exported?(mod, event, arity)
    end)
  end

  @doc false
  @spec contract(atom()) :: String.t()
  def contract(event), do: Map.fetch!(@contracts, event)

  @doc "Runs `on_prompt`. A halt returns the halting module and its reason."
  @spec prompt(map(), term()) :: {:cont, term()} | {:halt, module(), String.t()}
  def prompt(config, input) do
    case callable(config, :on_prompt) do
      [] ->
        {:cont, input}

      entries ->
        ctx = Context.build(config, :on_prompt, turn_id: nil)
        invoke = fn mod, value, opts -> mod.on_prompt(value, ctx, opts) end
        entries |> chain(ctx, %{}, input, invoke) |> string_halt()
    end
  end

  @doc "Runs `before_llm` with the call's `%{final: boolean(), iterations_left: integer()}`."
  @spec before_llm(map(), map()) :: :cont | {:halt, module(), String.t()}
  def before_llm(config, info) do
    case callable(config, :before_llm) do
      [] ->
        :cont

      entries ->
        ctx = Context.build(config, :before_llm)
        invoke = fn mod, value, opts -> mod.before_llm(value, ctx, opts) end
        entries |> chain(ctx, %{}, info, invoke) |> gate()
    end
  end

  @doc "Runs `before_tool`. A halt is the error result that answers the call."
  @spec before_tool(map(), ToolCall.t()) :: {:cont, ToolCall.t()} | {:halt, ToolResult.t()}
  def before_tool(config, %ToolCall{} = call) do
    case callable(config, :before_tool) do
      [] ->
        {:cont, call}

      entries ->
        ctx = Context.build(config, :before_tool)
        invoke = fn mod, value, opts -> mod.before_tool(value, ctx, opts) end
        entries |> chain(ctx, tool_meta(call), call, invoke) |> tool_halt(call)
    end
  end

  @doc "Runs `after_tool`; returns the result the model will see."
  @spec after_tool(map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def after_tool(config, %ToolCall{} = call, %ToolResult{} = result) do
    case callable(config, :after_tool) do
      [] ->
        result

      entries ->
        ctx = Context.build(config, :after_tool)
        invoke = fn mod, value, opts -> mod.after_tool(call, value, ctx, opts) end
        entries |> chain(ctx, tool_meta(call), result, invoke) |> answered(call)
    end
  end

  @doc "Runs `after_compact` with the compactor's dropped entries; returns the texts to inject."
  @spec after_compact(map(), [Entry.t()], map()) :: [String.t()]
  def after_compact(config, dropped, meta) do
    case callable(config, :after_compact) do
      [] ->
        []

      entries ->
        ctx = Context.build(config, :after_compact)
        collect(entries, ctx, fn mod, opts -> mod.after_compact(dropped, meta, ctx, opts) end)
    end
  end

  @doc "Runs `on_session_start`; returns the texts to inject."
  @spec session_start(map()) :: [String.t()]
  def session_start(config) do
    case callable(config, :on_session_start) do
      [] ->
        []

      entries ->
        ctx = Context.build(config, :on_session_start, turn_id: nil)
        collect(entries, ctx, fn mod, opts -> mod.on_session_start(ctx, opts) end)
    end
  end

  @doc "Runs `on_passivate` (logged-only)."
  @spec passivate(map()) :: :ok
  def passivate(config) do
    case callable(config, :on_passivate) do
      [] ->
        :ok

      entries ->
        ctx = Context.build(config, :on_passivate, turn_id: nil)
        _ = collect(entries, ctx, fn mod, opts -> mod.on_passivate(ctx, opts) end)
        :ok
    end
  end

  @doc "Runs `on_turn_end` (logged-only). `ctx_opts` go to `Normandy.Hooks.Context.build/3`."
  @spec turn_end(map(), Hooks.outcome(), keyword()) :: :ok
  def turn_end(config, outcome, ctx_opts \\ []) do
    case callable(config, :on_turn_end) do
      [] ->
        :ok

      entries ->
        ctx = Context.build(config, :on_turn_end, ctx_opts)
        _ = collect(entries, ctx, fn mod, opts -> mod.on_turn_end(outcome, ctx, opts) end)
        :ok
    end
  end

  # ── entry selection ─────────────────────────────────────────────────────────

  defp callable(config, event) do
    arity = Map.fetch!(@arity, event)

    for {mod, _opts} = entry <- entries(config),
        loaded?(mod, event),
        function_exported?(mod, event, arity),
        do: entry
  end

  # Validation catches a missing module on every path that builds a config; one that
  # slipped through is a configuration error, raised, except where nothing may raise.
  defp loaded?(mod, event) do
    cond do
      Code.ensure_loaded?(mod) ->
        true

      event in @logged_only ->
        Logger.error("hook module #{inspect(mod)} is not available; its #{event} did not run")
        false

      true ->
        raise ArgumentError, "hook module #{inspect(mod)} is not available"
    end
  end

  # ── chains ──────────────────────────────────────────────────────────────────

  # Threads `value` through the entries: {:cont, value} or {:halt, module, payload}, where
  # a :closed crash's payload is {:crashed, reason}.
  defp chain(entries, ctx, meta, value, invoke) do
    Enum.reduce_while(entries, {:cont, value}, fn {mod, _opts} = entry, {:cont, value} ->
      entry
      |> run_entry(ctx, meta, &invoke.(mod, value, &1), &classify(ctx.event, mod, value, &1))
      |> chain_step(mod, value)
    end)
  end

  defp chain_step({:cont, new}, _mod, _value), do: {:cont, {:cont, new}}
  defp chain_step({:halt, payload}, mod, _value), do: {:halt, {:halt, mod, payload}}

  defp chain_step({:rescued, :closed, reason}, mod, _value),
    do: {:halt, {:halt, mod, {:crashed, reason}}}

  defp chain_step({:rescued, _policy, _reason}, _mod, value), do: {:cont, {:cont, value}}

  # Runs every entry; returns the concatenated injections.
  defp collect(entries, ctx, invoke) do
    Enum.flat_map(entries, fn {mod, _opts} = entry ->
      case run_entry(entry, ctx, %{}, &invoke.(mod, &1), &classify(ctx.event, mod, nil, &1)) do
        {:inject, texts} -> texts
        _ok_or_rescued -> []
      end
    end)
  end

  defp string_halt({:halt, mod, {:crashed, reason}}), do: {:halt, mod, reason}
  defp string_halt(other), do: other

  defp gate({:cont, _info}), do: :cont
  defp gate(halt), do: string_halt(halt)

  defp tool_halt({:cont, call}, _call), do: {:cont, call}
  defp tool_halt({:halt, _mod, %ToolResult{} = result}, _call), do: {:halt, result}
  defp tool_halt({:halt, _mod, {:crashed, reason}}, call), do: {:halt, denial(call, reason)}
  defp tool_halt({:halt, _mod, reason}, call), do: {:halt, denial(call, reason)}

  defp answered({:cont, result}, _call), do: result

  defp answered({:halt, _mod, {:crashed, reason}}, call),
    do: %ToolResult{tool_call_id: call.id, output: %{error: reason}, is_error: true}

  defp denial(call, reason),
    do: %ToolResult{tool_call_id: call.id, output: %{error: reason, denied: true}, is_error: true}

  defp tool_meta(%ToolCall{id: id, name: name}), do: %{tool_call_id: id, tool: name}

  # ── one entry ───────────────────────────────────────────────────────────────

  # Calls one entry inside its span. Returns the classified value, or
  # {:rescued, policy, halt_reason} for a crash the entry's policy rescued.
  defp run_entry({mod, opts}, ctx, extra_meta, invoke, classify) do
    {policy, opts} = Keyword.pop(opts, :on_error, :reraise)
    policy = effective_policy(ctx.event, policy)

    meta =
      Map.merge(
        %{
          event: ctx.event,
          hook: mod,
          agent_name: ctx.agent_name,
          session_id: ctx.session_id,
          turn_id: ctx.turn_id
        },
        extra_meta
      )

    Span.span([:normandy, :hook], meta, fn ->
      {value, result} = invoke_entry(mod, ctx.event, policy, fn -> invoke.(opts) end, classify)
      {value, Map.put(meta, :result, result)}
    end)
  end

  defp invoke_entry(mod, event, policy, invoke, classify) do
    case guarded(policy, invoke) do
      {:ok, ret} ->
        {result, value} = classify.(ret)
        {value, result}

      {:crashed, kind, reason, stacktrace} ->
        Logger.error(
          "hook #{inspect(mod)} #{event} crashed: " <>
            TurnError.format_raised(kind, reason, stacktrace)
        )

        {{:rescued, policy, crash_reason(mod, kind, reason, stacktrace)}, :rescued}
    end
  end

  defp effective_policy(event, _policy) when event in @logged_only, do: :open
  defp effective_policy(event, :closed) when event not in @closable, do: :reraise
  defp effective_policy(_event, policy), do: policy

  defp guarded(:reraise, fun), do: {:ok, fun.()}

  defp guarded(_policy, fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:crashed, kind, reason, __STACKTRACE__}
  end

  # ── return contracts: {telemetry result, value for the chain} or ArgumentError ─

  defp classify(:on_prompt, _mod, value, {:cont, new}), do: pass_or_rewrite(value, new)

  defp classify(:before_tool, _mod, value, {:cont, %ToolCall{} = new}),
    do: pass_or_rewrite(value, new)

  defp classify(:after_tool, _mod, value, {:cont, %ToolResult{} = new}),
    do: pass_or_rewrite(value, new)

  defp classify(:before_llm, _mod, value, :cont), do: {:cont, {:cont, value}}

  defp classify(event, _mod, _value, {:halt, reason})
       when event in [:on_prompt, :before_llm, :before_tool] and is_binary(reason),
       do: {:halt, {:halt, reason}}

  defp classify(:before_tool, _mod, _value, {:halt, %ToolResult{} = result}),
    do: {:halt, {:halt, result}}

  defp classify(event, mod, _value, {:inject, texts} = ret) when event in @injecting do
    cond do
      not (is_list(texts) and Enum.all?(texts, &is_binary/1)) -> contract!(event, mod, ret)
      texts == [] -> {:ok, :ok}
      true -> {:inject, {:inject, texts}}
    end
  end

  defp classify(event, _mod, _value, _ret) when event in @injecting or event in @logged_only,
    do: {:ok, :ok}

  defp classify(event, mod, _value, ret), do: contract!(event, mod, ret)

  # Same value back is a pass; anything else is a rewrite.
  defp pass_or_rewrite(value, value), do: {:cont, {:cont, value}}
  defp pass_or_rewrite(_value, new), do: {:rewrite, {:cont, new}}

  @spec contract!(atom(), module(), term()) :: no_return()
  defp contract!(event, mod, ret) do
    raise ArgumentError,
          "expected #{inspect(mod)}.#{event}/#{Map.fetch!(@arity, event)} to return " <>
            "#{Map.fetch!(@contracts, event)}, got: #{inspect(ret)}"
  end

  # ── crash descriptions ──────────────────────────────────────────────────────

  # A halt reason reaches the model or the caller: the exception module or the kind only.
  defp crash_reason(mod, :error, reason, stacktrace) do
    %exception{} = Exception.normalize(:error, reason, stacktrace)
    "hook #{inspect(mod)} crashed: #{inspect(exception)}"
  end

  defp crash_reason(mod, kind, _reason, _stacktrace), do: "hook #{inspect(mod)} crashed: #{kind}"
end
