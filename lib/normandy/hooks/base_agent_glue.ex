defmodule Normandy.Hooks.BaseAgentGlue do
  @moduledoc false
  # BaseAgent's hook call sites, so base_agent.ex keeps one-line calls. An agent with no
  # hooks does no hook work: each function checks Runner.hooks?/1 first.

  alias Normandy.HookHaltError
  alias Normandy.Hooks.Runner

  @doc "Runs `on_prompt` on the validated input; raises `HookHaltError` on a halt."
  @spec prompt!(map(), term()) :: term()
  def prompt!(config, input) do
    if Runner.hooks?(config), do: run_prompt!(config, input), else: input
  end

  defp run_prompt!(config, input) do
    case Runner.prompt(config, input) do
      {:cont, admitted} ->
        admitted

      {:halt, hook, reason} ->
        raise HookHaltError, event: :on_prompt, hook: hook, reason: reason
    end
  end
end
