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
end
