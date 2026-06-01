defmodule Normandy.Guardrails.Gate do
  @moduledoc """
  Redirect-aware admission front door for an agent.

  Call `run/3` instead of `BaseAgent.run/2`. It assembles a guard stack — an
  optional cheap deny-list plus `Normandy.Guardrails.Builtins.LlmRelevanceGuard`
  as the sole arbiter of on/off-topic — and runs it through the non-raising
  `Normandy.Guardrails.run/2`:

    * pass  → delegates to `BaseAgent.run/2` (a real turn).
    * block → returns a polite redirect response **without** invoking the agent
      and **without** touching agent memory, plus a
      `[:normandy, :agent, :guardrail, :violation]` telemetry event with
      `stage: :relevance`.

  The redirect is built from the agent's configured `output_schema` so callers
  can't tell it apart from a normal turn structurally.

  ## Options

  - `:relevance` (keyword list, required) — opts for `LlmRelevanceGuard`. The
    agent's own `:client` is injected automatically unless you pass one.
  - `:deny` (list of guard specs, default `[]`) — cheap guards run before the LLM.
  - `:redirect_message` (required) — text returned when a message is blocked.
  - `:redirect_field` (atom, default `:chat_message`) — output-schema field the
    redirect message is placed in.
  """

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, BaseAgentOutputSchema}
  alias Normandy.Guardrails.Builtins.LlmRelevanceGuard

  @spec run(BaseAgentConfig.t(), String.t(), keyword()) :: {BaseAgentConfig.t(), struct()}
  def run(%BaseAgentConfig{} = agent, message, opts) do
    relevance = Keyword.get(opts, :relevance, [])
    deny = Keyword.get(opts, :deny, [])
    redirect_message = Keyword.fetch!(opts, :redirect_message)
    redirect_field = Keyword.get(opts, :redirect_field, :chat_message)

    relevance_spec = {LlmRelevanceGuard, Keyword.put_new(relevance, :client, agent.client)}
    guards = deny ++ [relevance_spec]

    case Normandy.Guardrails.run(guards, message) do
      {:ok, _value} ->
        BaseAgent.run(agent, message)

      {:error, violations} ->
        emit_violation(agent, guards, violations)
        {agent, redirect_response(agent, redirect_field, redirect_message)}
    end
  end

  defp redirect_response(agent, field, message) do
    module =
      case agent.output_schema do
        %{__struct__: mod} -> mod
        _ -> BaseAgentOutputSchema
      end

    struct(module, %{field => message})
  end

  defp emit_violation(agent, guards, violations) do
    :telemetry.execute(
      [:normandy, :agent, :guardrail, :violation],
      %{count: length(violations)},
      %{
        stage: :relevance,
        agent_name: agent.name,
        guards: Enum.map(guards, &guard_module/1),
        violations: violations
      }
    )
  end

  defp guard_module(mod) when is_atom(mod), do: mod
  defp guard_module({mod, _opts}), do: mod
end
