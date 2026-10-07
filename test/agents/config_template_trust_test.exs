defmodule Normandy.Agents.ConfigTemplateTrustTest do
  # SEC-8: a template read from the store is checked before anything in it is used, and a
  # supplement's :pinned fixes the security settings a store writer could swap.
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.PolicyEngine.{AllowAll, Ruleset}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  # Reports each token request to the process registered under opts[:notify].
  defmodule NotifyingCreds do
    @moduledoc false
    @behaviour Normandy.Behaviours.CredentialProvider
    @impl true
    def get_token(_provider, opts) do
      send(Keyword.fetch!(opts, :notify), :token_requested)
      {:ok, "TOKEN"}
    end
  end

  defmodule NotAGuard do
    @moduledoc false
    def check(_value, _opts), do: :ok
  end

  @ruleset {Ruleset,
            rules: [%{match: "srv__*", action: :require_approval}], default_action: :deny}

  defp template(overrides \\ %{}) do
    TurnConfig.build()
    |> Map.merge(overrides)
    |> ConfigTemplate.from_config("kind-a")
  end

  defp supplement(extra \\ %{}) do
    Map.merge(
      %{
        toolset: nil,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn token -> %{api_key: token} end
      },
      extra
    )
  end

  defp message!(fun), do: assert_raise(ArgumentError, fun).message

  describe "check_loaded!/1" do
    test "a template from_config/2 wrote passes" do
      assert ConfigTemplate.check_loaded!(template()) == :ok
    end

    test "a function anywhere is refused, naming the field and never the value" do
      tmpl = Map.put(template(), :tool_context, %{cb: fn x -> {x, "SECRET"} end})

      message = message!(fn -> ConfigTemplate.check_loaded!(tmpl) end)

      assert message ==
               ~s(Normandy.Agents.ConfigTemplate.check_loaded!/1: template "kind-a" :tool_context ) <>
                 "holds a function, pid, reference or port; it is not used (see the Trust " <>
                 "boundary section of Normandy.Agents.ConfigTemplate)"

      refute message =~ "SECRET"
    end

    test "a pid or a reference inside guard opts is refused" do
      for bad <- [self(), make_ref()] do
        tmpl =
          Map.put(template(), :guardrails,
            input: [{Normandy.Guardrails.Builtins.MaxLength, limit: 3, owner: bad}]
          )

        assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) =~
                 ~s(template "kind-a" :guardrails holds a function, pid, reference or port)
      end
    end

    test "a behaviours_refs module that does not implement its behaviour is refused" do
      for {slot, mod, behaviour} <- [
            {:policy, String, "Normandy.Behaviours.PolicyEngine"},
            {:budget, Nope.Missing, "Normandy.Behaviours.BudgetTracker"},
            {:credential, AllowAll, "Normandy.Behaviours.CredentialProvider"}
          ] do
        tmpl = put_in(template().behaviours_refs[slot], {mod, []})

        assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) ==
                 ~s(Normandy.Agents.ConfigTemplate.check_loaded!/1: template "kind-a" ) <>
                   "behaviours_refs #{inspect(slot)} must be {module, keyword} whose module is " <>
                   "loaded on this node and implements #{behaviour}, got: #{inspect(mod)}; it is " <>
                   "not used (see the Trust boundary section of Normandy.Agents.ConfigTemplate)"
      end
    end

    test "a behaviours_refs slot that is not {module, keyword} is refused without showing it" do
      tmpl = put_in(template().behaviours_refs[:policy], %{api_key: "SECRET"})

      message = message!(fn -> ConfigTemplate.check_loaded!(tmpl) end)
      assert message =~ "behaviours_refs :policy must be {module, keyword}"
      assert message =~ "got: a map;"
      refute message =~ "SECRET"
    end

    test "a guard module that is not a Guard is refused" do
      tmpl = Map.put(template(), :guardrails, output: [NotAGuard])

      assert message!(fn -> ConfigTemplate.check_loaded!(tmpl) end) =~
               ":guardrails :output guard #{inspect(NotAGuard)} is not loaded on this node or " <>
                 "does not implement Normandy.Guardrails.Guard"
    end

    test "rebuild/3 runs the same check first" do
      tmpl = put_in(template().behaviours_refs[:policy], {String, []})

      assert message!(fn -> ConfigTemplate.rebuild(tmpl, supplement(), "T") end) =~
               "check_loaded!/1: template \"kind-a\" behaviours_refs :policy"
    end
  end

  describe "the supplement's :pinned" do
    test "a template whose pinned field differs is refused; an equal one rebuilds" do
      tmpl = template()
      pinned = supplement(%{pinned: [policy: @ruleset]})

      assert message!(fn -> ConfigTemplate.rebuild(tmpl, pinned, "T") end) ==
               ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "kind-a" has a :policy that ) <>
                 "differs from the one this node's supplement pins; it is not used (see the " <>
                 "Trust boundary section of Normandy.Agents.ConfigTemplate)"

      tmpl = put_in(tmpl.behaviours_refs[:policy], @ruleset)
      assert ConfigTemplate.rebuild(tmpl, pinned, "T").behaviours.policy == @ruleset
    end

    test "guardrails and the credential can be pinned too" do
      tmpl = template()
      guards = [input: [{Normandy.Guardrails.Builtins.MaxLength, limit: 10}]]

      assert_raise ArgumentError, ~r/has a :guardrails that differs/, fn ->
        ConfigTemplate.rebuild(tmpl, supplement(%{pinned: [guardrails: guards]}), "T")
      end

      assert_raise ArgumentError, ~r/has a :credential that differs/, fn ->
        ConfigTemplate.rebuild(
          tmpl,
          supplement(%{pinned: [credential: {NotifyingCreds, []}]}),
          "T"
        )
      end
    end

    test "a field that cannot be pinned is refused, naming it" do
      assert message!(fn ->
               ConfigTemplate.rebuild(template(), supplement(%{pinned: [tool_context: %{}]}), "T")
             end) ==
               "Normandy.Agents.ConfigTemplate.rebuild/3: the supplement pins :tool_context; " <>
                 ":pinned takes :policy, :budget, :credential, :compactor, :model_catalog, " <>
                 ":hooks, :guardrails"
    end
  end

  describe "Turn.Server" do
    defp handlers do
      %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %TurnConfig.Resp{content: "hi", tool_calls: nil} end
      }
    end

    defp thin_start(tmpl, supp) do
      name = :"creds_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      tmpl = put_in(tmpl.behaviours_refs[:credential], {NotifyingCreds, [notify: name]})

      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:started, thin_start_as_is(tmpl, supp)})
      end)

      assert_received {:started, srv}
      srv
    end

    # Stores the template unchanged (no notifying credential provider put in); logs are
    # the caller's to capture.
    defp thin_start_as_is(tmpl, supp) do
      store = InMemory.new()
      sid = "trust-#{System.unique_integer([:positive])}"
      :ok = InMemory.save_config_template(store, sid, tmpl)
      {:ok, cat} = Catalog.start_link([])
      :ok = Catalog.put(cat, "kind-a", supp)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          template_provider: {Catalog, cat},
          handlers: handlers()
        )

      srv
    end

    test "a template with a function in it is never used, and no token is requested" do
      tmpl = Map.put(template(), :tool_context, %{cb: fn -> :x end})
      srv = thin_start(tmpl, supplement())

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, "hello")

      assert message =~ ":tool_context holds a function, pid, reference or port"
      refute_received :token_requested
    end

    test "a swapped policy is refused before the template's credential provider runs" do
      srv = thin_start(template(), supplement(%{pinned: [policy: @ruleset]}))

      assert {:error,
              %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
               Turn.Server.run(srv, "hello")

      assert message =~ "has a :policy that differs from the one this node's supplement pins"
      refute_received :token_requested
    end

    # A template missing what reconstruction reads first is refused like any other, not
    # a KeyError in init/1 (a restart loop whose crash log inspected the credential opts).
    test "a template with no template_id, a non-map behaviours_refs or no credential waits :unavailable" do
      creds = {NotifyingCreds, [notify: :nobody, api_key: "SECRET-CRED"]}
      with_creds = put_in(template().behaviours_refs[:credential], creds)

      cases = [
        {Map.delete(with_creds, :template_id), "lacks the field :template_id"},
        {%{with_creds | behaviours_refs: Map.to_list(with_creds.behaviours_refs)},
         "has a behaviours_refs that is not a map"},
        {update_in(with_creds.behaviours_refs, fn refs ->
           refs
           |> Map.delete(:credential)
           |> Map.put(:budget, {Normandy.Behaviours.BudgetTracker.NoOp, [token: "SECRET-CRED"]})
         end), "lacks the behaviours_refs slot :credential"}
      ]

      for {tmpl, expected} <- cases do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            srv = thin_start_as_is(tmpl, supplement())

            assert {:error,
                    %TurnError{type: :session_unavailable, reason: {:invalid_template, message}}} =
                     Turn.Server.run(srv, "hello")

            assert message =~ expected
            refute message =~ "SECRET"
            assert Process.alive?(srv)
          end)

        refute log =~ "SECRET"
      end
    end

    test "a template that passes runs as before" do
      srv =
        thin_start(
          put_in(template().behaviours_refs[:policy], @ruleset),
          supplement(%{pinned: [policy: @ruleset]})
        )

      assert {:ok, _output} = Turn.Server.run(srv, "hello")
      assert_received :token_requested
    end
  end
end
