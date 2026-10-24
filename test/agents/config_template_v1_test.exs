defmodule Normandy.Agents.ConfigTemplateV1Test do
  # Review Focus #1: a session template saved by Normandy 1.0.0, rebuilt under 2.0.
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionStore.Codec
  alias Normandy.Test.StubClient

  # Written by v1.0.0's own ConfigTemplate.from_config/3 (generate_v1_0_0.exs, same
  # directory) and stored as a 1.0 Postgres/Redis store kept it: term_to_binary/1.
  @fixture Path.expand("../fixtures/templates/v1_0_0_session_template.etf", __DIR__)

  # The fixture names 1.0's default credential provider, CredentialProvider.FromClient,
  # which 2.0 removed: as stored it is refused (the test below). The other tests
  # rebuild it with a provider this node has, as a 2.0 deployment configures one.
  defp stored_v1_template, do: @fixture |> File.read!() |> Codec.decode()

  defp v1_template,
    do: put_in(stored_v1_template().behaviours_refs.credential, {Normandy.Test.StubCreds, []})

  defp supplement do
    %{
      toolset: nil,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token ->
        %StubClient{notify: self(), reply: fn model -> %{model | chat_message: "hello"} end}
      end
    }
  end

  defp rebuild(tmpl), do: ConfigTemplate.rebuild(tmpl, supplement(), "token")

  test "the fixture has the 1.0 shape the translation is for" do
    tmpl = v1_template()

    assert tmpl.max_tokens == nil
    assert Map.has_key?(tmpl.behaviours_refs, :session_store)
    assert Map.has_key?(tmpl.behaviours_refs, :session_registry)
    refute Map.has_key?(tmpl, :node_local_fields)

    assert tmpl.behaviours_refs.compactor ==
             {Compactor.WindowManager, [max_tokens: 200_000, strategy: :oldest_first]}
  end

  test "as stored, its credential provider (1.0's FromClient, removed in 2.0) is refused" do
    assert {Normandy.Behaviours.CredentialProvider.FromClient, []} =
             stored_v1_template().behaviours_refs.credential

    assert_raise ArgumentError,
                 ~r/CredentialProvider.FromClient, which was removed in 2.0; set the config's behaviours :credential to a Normandy.Behaviours.CredentialProvider module/,
                 fn -> rebuild(stored_v1_template()) end
  end

  test "it rebuilds into a working config with 2.0 defaults" do
    config = rebuild(v1_template())

    assert %BaseAgentConfig{model: "claude-sonnet-4-6", temperature: 0.9, name: "support"} =
             config

    assert config.max_tokens == BaseAgentConfig.default_max_tokens()
    assert config.memory.max_messages == 50
    assert config.prompt_specification.background == ["You answer billing questions."]
    assert config.retry == nil
    assert config.circuit_breaker == nil
    refute Map.has_key?(config, :circuit_breaker_pid)
    assert config.guardrails == BaseAgentConfig.default_guardrails()
    assert config.tool_context == %{}
    assert config.behaviours.hooks == []
    refute Map.has_key?(config.behaviours, :session_store)
    refute Map.has_key?(config.behaviours, :session_registry)

    {mod, opts} = config.behaviours.compactor
    assert mod == Compactor.WindowManager
    assert Keyword.fetch!(opts, :context_window) == 200_000
    assert Keyword.fetch!(opts, :strategy) == :oldest_first
    refute Keyword.has_key?(opts, :max_tokens)

    assert {:ok, _config, %BaseAgentOutputSchema{chat_message: "hello"}} =
             BaseAgent.run(config, "hi")

    assert_receive {:converse, %Normandy.LLM.Request{max_tokens: 16_000}, _opts}
  end

  # Pinned with :context_window, so the rebuild needs no catalog lookup for StubClient.
  test "a custom compactor's :max_tokens is not rewritten" do
    tmpl =
      put_in(
        v1_template().behaviours_refs.compactor,
        {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9, context_window: 100_000]}
      )

    assert rebuild(tmpl).behaviours.compactor ==
             {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9, context_window: 100_000]}
  end

  test "a field neither 1.0 nor 2.0 writes raises, naming it" do
    tmpl = Map.put(v1_template(), :retry_options, max_attempts: 2)

    assert_raise ArgumentError,
                 ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "tmpl-v1" has the field :retry_options, ) <>
                   "which neither a Normandy 1.0 nor a 2.0 template has; it cannot be rebuilt " <>
                   "(MIGRATING-2.0.md §22)",
                 fn -> rebuild(tmpl) end
  end

  test "the pre-release field names raise instead of being dropped (3.2b carry)" do
    for field <- [:retry_options, :input_guardrails, :output_guardrails] do
      tmpl = Map.put(v1_template(), field, [])

      assert_raise ArgumentError, ~r/has the field #{inspect(field)}, which neither/, fn ->
        rebuild(tmpl)
      end
    end
  end

  test "an unknown behaviours_refs slot raises, naming it" do
    tmpl = put_in(v1_template().behaviours_refs[:sandbox], {SomeSandbox, []})

    assert_raise ArgumentError,
                 ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "tmpl-v1" has the behaviours_refs slot ) <>
                   ":sandbox, which neither a Normandy 1.0 nor a 2.0 template has; it cannot " <>
                   "be rebuilt (MIGRATING-2.0.md §22)",
                 fn -> rebuild(tmpl) end
  end

  test "a missing required field raises, naming it" do
    assert_raise ArgumentError,
                 ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "tmpl-v1" lacks the field :model, ) <>
                   "which every Normandy 1.0 and 2.0 template has; it cannot be rebuilt " <>
                   "(MIGRATING-2.0.md §22)",
                 fn -> v1_template() |> Map.delete(:model) |> rebuild() end
  end

  test "a missing required behaviours_refs slot raises, naming it" do
    tmpl = update_in(v1_template().behaviours_refs, &Map.delete(&1, :credential))

    assert_raise ArgumentError, ~r/lacks the behaviours_refs slot :credential/, fn ->
      rebuild(tmpl)
    end
  end

  test "an unreleased node_local_fields entry raises, naming it" do
    tmpl = Map.put(v1_template(), :node_local_fields, [:circuit_breaker])

    assert_raise ArgumentError, ~r/lists :circuit_breaker in :node_local_fields/, fn ->
      rebuild(tmpl)
    end
  end

  test "a max_tokens that is neither nil nor a positive integer raises, naming it" do
    for bad <- [0, -1, false, "16000"] do
      assert_raise ArgumentError,
                   ~s(Normandy.Agents.ConfigTemplate.rebuild/3: template "tmpl-v1" has max_tokens ) <>
                     "#{inspect(bad)}; expected a positive integer, or nil (a 1.0 template " <>
                     "that set none)",
                   fn -> v1_template() |> Map.put(:max_tokens, bad) |> rebuild() end
    end
  end

  test "both window pins on Compactor.WindowManager raise" do
    tmpl =
      put_in(
        v1_template().behaviours_refs.compactor,
        {Compactor.WindowManager, [max_tokens: 1_000, context_window: 2_000]}
      )

    assert_raise ArgumentError, ~r/both :max_tokens \(1.0\) and :context_window \(2.0\)/, fn ->
      rebuild(tmpl)
    end
  end

  test "a 2.0 template round-trips through the same checks" do
    config = rebuild(v1_template())
    tmpl = ConfigTemplate.from_config(config, "tmpl-v2", :eager)

    refute Map.has_key?(tmpl.behaviours_refs, :session_store)
    assert rebuild(tmpl).behaviours.compactor == config.behaviours.compactor
  end
end
