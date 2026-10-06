defmodule Normandy.Behaviours.PolicyEngine do
  @moduledoc """
  Contract for per-tool-call policy decisions, consulted at the dispatch
  chokepoint via `Normandy.Behaviours.Config.to_pipeline/1`.

  `check/2` gets the `%ToolCall{}` and a ctx map: `config` (the agent config), `tool` (the
  tool struct as registered; the model's input is never merged into it), `input` (the
  model's input after `Normandy.Tools.Input.validate/2`: the tool's input-schema struct, or
  a string-keyed map) and `opts` (the policy ref's opts). It returns one of:

    * `{:allow, meta}` — proceed; `meta` is opaque allow-context.
    * `{:deny, info}` — block; `info` may carry `:reason`, `:rule_id`,
      `:rationale`. The rationale is fed back into the model context by the
      chokepoint, so the model learns *why* a constraint exists.
    * `{:needs_approval, info}` — park for human approval (interim-tagged in
      Phase 1; real parking lands in Phase 4).

  The default impl `AllowAll` preserves current (allow-everything) behavior.
  """

  @type call :: term()
  @type ctx :: map()
  @type decision :: {:allow, map()} | {:deny, map()} | {:needs_approval, map()}

  @callback check(call(), ctx()) :: decision()

  @doc """
  Optional: checks the `opts` half of the policy ref when the agent is built
  (`BaseAgent.init/1`), raising `ArgumentError` on a malformed policy, so a
  mistake surfaces at configuration instead of on the first tool call.
  """
  @callback validate_opts!(keyword()) :: :ok
  @optional_callbacks validate_opts!: 1

  defmodule AllowAll do
    @moduledoc "Default PolicyEngine: allows every call (back-compat)."
    @behaviour Normandy.Behaviours.PolicyEngine

    @impl true
    def check(_call, _ctx), do: {:allow, %{}}
  end

  defmodule Ruleset do
    @moduledoc """
    PolicyEngine that evaluates an ordered list of in-memory rules, first match
    wins, with a configurable default action. The ruleset is supplied as a
    **keyword list** on `ctx.opts` (the `opts` half of the bundle's
    `{module, opts}` ref — always a keyword list by construction):

      * `:rules` (required) — list of `%{match, action, rule_id, rationale}`
        maps. `match` (required) is a tool-name glob: `"*"` (matches all),
        `"prefix_*"` (trailing `*` only — prefix match), or an exact name.
        `action` (required) is `:allow | :deny | :require_approval`.
      * `:default_action` (required) — action when no rule matches. There is no
        implicit `:allow`: a policy states what an unmatched call gets.

    A rule sees the tool's name only. An MCP server or a remote A2A agent chooses its own
    tools' names, so match those on the prefix you gave them (`"srv__*"`, see
    `Normandy.MCP.ToolWrapper`'s "Tool names and policy rules"), never on a name such as
    `"read_*"` that a server can choose to match.

    A malformed ruleset raises `ArgumentError`: when the agent is built
    (`validate_opts!/1`), and again in `check/2`, which the dispatch chokepoint
    turns into a denial. It never fails open.

    A YAML-file loader is intentionally deferred — YAML is only a serialization
    of this in-memory shape.
    """
    @behaviour Normandy.Behaviours.PolicyEngine

    @actions [:allow, :deny, :require_approval]

    @impl true
    def check(call, ctx) do
      opts = Map.get(ctx, :opts, [])
      :ok = validate_opts!(opts)
      name = call_name(call)

      case Enum.find(Keyword.fetch!(opts, :rules), fn rule -> matches?(rule.match, name) end) do
        nil -> decide(Keyword.fetch!(opts, :default_action), empty_meta())
        rule -> decide(rule.action, rule_meta(rule))
      end
    end

    @impl true
    def validate_opts!(opts) do
      rules =
        case Keyword.fetch(opts, :rules) do
          {:ok, rules} when is_list(rules) ->
            rules

          _ ->
            raise ArgumentError, "PolicyEngine.Ruleset: :rules is required (a list of rule maps)"
        end

      case Keyword.fetch(opts, :default_action) do
        {:ok, action} when action in @actions ->
          :ok

        {:ok, other} ->
          raise ArgumentError,
                "PolicyEngine.Ruleset: :default_action must be one of #{inspect(@actions)}, " <>
                  "got: #{inspect(other)}"

        :error ->
          raise ArgumentError,
                "PolicyEngine.Ruleset: :default_action is required (one of #{inspect(@actions)})"
      end

      rules |> Enum.with_index() |> Enum.each(fn {rule, index} -> validate_rule!(rule, index) end)
    end

    defp validate_rule!(%{match: match, action: action}, _index)
         when is_binary(match) and action in @actions,
         do: :ok

    defp validate_rule!(%{match: match} = rule, index) when is_binary(match) do
      raise ArgumentError,
            "PolicyEngine.Ruleset: rule #{index} needs :action (one of #{inspect(@actions)}), " <>
              "got: #{inspect(rule)}"
    end

    defp validate_rule!(rule, index) do
      raise ArgumentError,
            "PolicyEngine.Ruleset: rule #{index} needs :match (a tool-name glob string), " <>
              "got: #{inspect(rule)}"
    end

    defp call_name(%{name: name}) when is_binary(name), do: name
    defp call_name(_), do: ""

    defp empty_meta, do: %{reason: nil, rule_id: nil, rationale: nil}

    defp rule_meta(rule) do
      %{
        reason: rule[:reason] || rule[:rationale],
        rule_id: rule[:rule_id],
        rationale: rule[:rationale]
      }
    end

    defp decide(:allow, _meta), do: {:allow, %{}}
    defp decide(:deny, meta), do: {:deny, meta}
    defp decide(:require_approval, meta), do: {:needs_approval, meta}

    defp matches?("*", _name), do: true

    defp matches?(pattern, name) when is_binary(pattern) do
      if String.ends_with?(pattern, "*") do
        String.starts_with?(name, String.trim_trailing(pattern, "*"))
      else
        pattern == name
      end
    end
  end
end
