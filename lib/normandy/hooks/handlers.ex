defmodule Normandy.Hooks.Handlers do
  @moduledoc false
  # Wraps a `Normandy.Agents.Turn.Driver.Handlers` set so `before_llm` and `after_compact`
  # hooks run whatever handlers a shell was given: BaseAgent wraps its own sets once per
  # drive. Turn.Server keeps its set unwrapped and calls `before_llm!/3` and
  # `after_compact/2` itself (Normandy.Hooks.ServerGlue), apart from the client and the
  # compactor, so it can tell a hook's crash from theirs. The default sets hold no hook
  # calls, so no hook runs twice. A config with no entry exporting a callback gets its
  # handler back unwrapped.
  #
  # `wrap/2` is not idempotent: wrapping a set twice runs each hook twice. A handler set is
  # a `Driver.Handlers` struct with no room for a "wrapped" marker, so never wrap a set
  # that is already wrapped.

  alias Normandy.Agents.Turn.Driver
  alias Normandy.Components.AgentMemory
  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner

  # Internal to the shells (BaseAgent, Turn.Server); see the moduledoc: never wrap a wrapped set.
  @doc false
  @spec wrap(Driver.Handlers.t(), map() | nil) :: Driver.Handlers.t()
  def wrap(%Driver.Handlers{} = handlers, config) do
    handlers
    |> wrap_call_llm(Runner.handles?(config, :before_llm))
    |> wrap_compact(Runner.handles?(config, :after_compact))
  end

  defp wrap_call_llm(handlers, false), do: handlers

  defp wrap_call_llm(%Driver.Handlers{call_llm: call_llm} = handlers, true) do
    %{
      handlers
      | call_llm: fn config, state, request ->
          :ok = before_llm!(config, state, request)
          call_llm.(config, state, request)
        end
    }
  end

  defp wrap_compact(handlers, false), do: handlers

  defp wrap_compact(%Driver.Handlers{compact: compact} = handlers, true) do
    %{
      handlers
      | compact: fn config, state, info ->
          {compacted, meta} = compact.(config, state, info)
          {after_compact(compacted, meta), meta}
        end
    }
  end

  @doc false
  # Runs `before_llm` for one LLM call; a halt raises Normandy.HookHaltError. Outside the
  # llm_call span and the retry loop (both live in the wrapped handler): a halt is a
  # decision, not a failed call, so it is neither retried nor recorded as an LLM exception.
  @spec before_llm!(map(), Normandy.Agents.Turn.State.t(), map()) :: :ok
  def before_llm!(config, state, request) do
    info = %{final: request.final, iterations_left: state.iterations_left}

    case Runner.before_llm(config, info) do
      :cont -> :ok
      {:halt, hook, reason} -> raise HookHaltError, event: :before_llm, hook: hook, reason: reason
    end
  end

  @doc false
  # Runs `after_compact` on a compaction's result; returns the compacted config with any
  # injected texts in its memory. Only a compaction that reports what it removed (meta.dropped, see
  # Normandy.Behaviours.Compactor) has anything to tell. Injected texts are appended to
  # the compacted memory, before the next LLM call. They are not stored as messages of
  # their own; Turn.Server stores them inside the "compaction" snapshot it writes after
  # the compaction (AgentMemory.compaction_content/1), so a restored session keeps them.
  @spec after_compact(map(), map()) :: map()
  def after_compact(config, %{dropped: [_ | _] = dropped} = meta) do
    case Runner.after_compact(config, dropped, Map.delete(meta, :dropped)) do
      [] ->
        config

      texts ->
        memory = Enum.reduce(texts, config.memory, &AgentMemory.add_message(&2, "user", &1))
        %{config | memory: memory}
    end
  end

  def after_compact(config, _meta), do: config
end
