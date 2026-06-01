defmodule Normandy.Behaviours.PolicyEngine do
  @moduledoc """
  Contract for per-tool-call policy decisions, consulted at the dispatch
  chokepoint via `Normandy.Behaviours.Config.to_pipeline/1`.

  `check/2` returns one of:

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

      * `:rules` — list of `%{match, action, rule_id, rationale}` maps. `match`
        is a tool-name glob: `"*"` (matches all), `"prefix_*"` (trailing `*`
        only — prefix match), or an exact name. `action` is
        `:allow | :deny | :require_approval`.
      * `:default_action` — action when no rule matches (default `:allow`).

    A YAML-file loader is intentionally deferred — YAML is only a serialization
    of this in-memory shape.
    """
    @behaviour Normandy.Behaviours.PolicyEngine

    @impl true
    def check(call, ctx) do
      opts = Map.get(ctx, :opts, [])
      rules = Keyword.get(opts, :rules, [])
      default_action = Keyword.get(opts, :default_action, :allow)
      name = call_name(call)

      case Enum.find(rules, fn rule -> matches?(rule[:match], name) end) do
        nil -> decide(default_action, empty_meta())
        rule -> decide(rule[:action] || :allow, rule_meta(rule))
      end
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
    defp matches?(nil, _name), do: false

    defp matches?(pattern, name) when is_binary(pattern) do
      if String.ends_with?(pattern, "*") do
        String.starts_with?(name, String.trim_trailing(pattern, "*"))
      else
        pattern == name
      end
    end

    defp matches?(_pattern, _name), do: false
  end
end
