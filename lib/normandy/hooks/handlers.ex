defmodule Normandy.Hooks.Handlers do
  @moduledoc """
  Wraps a `Normandy.Agents.Turn.Driver.Handlers` set so `before_llm` and `after_compact`
  hooks run whatever handlers a shell was given: BaseAgent's own sets, or the `:handlers`
  a caller passes to `Turn.Server`. Each shell wraps its set once, and the default sets
  hold no hook calls, so no hook runs twice. A config with no entry exporting a callback
  gets its handler back unwrapped.
  """

  alias Normandy.Agents.Turn.Driver
  alias Normandy.Components.AgentMemory
  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner

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

  # Outside the llm_call span and the retry loop (both live in the wrapped handler): a
  # halt is a decision, not a failed call, so it is neither retried nor recorded as an
  # LLM exception.
  defp before_llm!(config, state, request) do
    info = %{final: Map.get(request, :final, false), iterations_left: state.iterations_left}

    case Runner.before_llm(config, info) do
      :cont -> :ok
      {:halt, hook, reason} -> raise HookHaltError, event: :before_llm, hook: hook, reason: reason
    end
  end

  # Only a compaction that reports what it removed (meta.dropped, see
  # Normandy.Behaviours.Compactor) has anything to tell. Injected texts are appended to
  # the compacted memory, before the next LLM call; Turn.Server never stores compacted
  # memory, so they stay out of the session store.
  defp after_compact(config, %{dropped: [_ | _] = dropped} = meta) do
    case Runner.after_compact(config, dropped, Map.delete(meta, :dropped)) do
      [] ->
        config

      texts ->
        memory = Enum.reduce(texts, config.memory, &AgentMemory.add_message(&2, "user", &1))
        %{config | memory: memory}
    end
  end

  defp after_compact(config, _meta), do: config
end
