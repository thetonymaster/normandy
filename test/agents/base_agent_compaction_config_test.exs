defmodule Normandy.Agents.BaseAgentCompactionConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.{Compactor, Config}

  defmodule OtherClient do
    defstruct api_key: "sk-secret-do-not-print"

    # init/1 takes only a client that implements the protocol; these tests never call it.
    defimpl Normandy.Agents.Model do
      def converse(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defmodule CustomCatalog do
    @behaviour Normandy.Behaviours.ModelCatalog
    @impl true
    def context_window(_model, _opts), do: {:ok, 100_000}
  end

  defp init(client, behaviours) do
    BaseAgent.init(%{client: client, model: "m", temperature: nil, behaviours: behaviours})
  end

  @pinned %Config{compactor: {Compactor.WindowManager, [context_window: 50_000]}}
  @unpinned %Config{compactor: {Compactor.WindowManager, [reserved_tokens: 16]}}

  test "a non-Claudio client with an unpinned compactor and the default catalog raises at init" do
    error = assert_raise ArgumentError, fn -> init(%OtherClient{}, @unpinned) end

    assert error.message =~ ~r/^Normandy\.Agents\.BaseAgent\.init\/1: compactor /
    assert error.message =~ "Compactor.WindowManager"
    assert error.message =~ ":context_window"
    assert error.message =~ "OtherClient"
    refute error.message =~ "sk-secret"
  end

  test "compactor opts that are not a keyword list raise a named ArgumentError" do
    behaviours = %Config{compactor: {Compactor.WindowManager, %{}}}
    error = assert_raise ArgumentError, fn -> init(%OtherClient{}, behaviours) end

    assert error.message =~ "Normandy.Agents.BaseAgent.init/1: "
    assert error.message =~ "Compactor.WindowManager"
    assert error.message =~ "keyword list"
    refute error.message =~ "sk-secret"
  end

  test "the deprecated Static catalog is treated like the default" do
    # Built at runtime: a compiled Static literal under test/ would make the 1.x
    # [:safe] decode test in config_template_test vacuous (one shared VM).
    static = Module.safe_concat([Normandy.Behaviours.ModelCatalog, "Static"])
    behaviours = %{@unpinned | model_catalog: {static, []}}
    assert_raise ArgumentError, fn -> init(%OtherClient{}, behaviours) end
  end

  test "passes when :context_window is pinned" do
    pinned = %Config{compactor: {Compactor.WindowManager, [context_window: 50_000]}}
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, pinned)
  end

  test "the 1.x :max_tokens pin on Compactor.WindowManager raises at init, naming :context_window" do
    behaviours = %Config{compactor: {Compactor.WindowManager, [max_tokens: 50_000]}}

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: the :max_tokens " <>
                   "option of Normandy.Behaviours.Compactor.WindowManager was renamed to " <>
                   ":context_window in 2.0; see MIGRATING-2.0.md §22",
                 fn -> init(%Normandy.LLM.ClaudioAdapter{api_key: "k"}, behaviours) end
  end

  test "a custom compactor's own :max_tokens option is left alone" do
    behaviours = %Config{compactor: {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9]}}

    assert %Normandy.Agents.BaseAgentConfig{} =
             init(%Normandy.LLM.ClaudioAdapter{api_key: "k"}, behaviours)
  end

  test "passes with the NoOp compactor (the default)" do
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, nil)
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, %Config{})
  end

  test "passes with a Claudio client" do
    client = %Normandy.LLM.ClaudioAdapter{api_key: "k"}
    assert %Normandy.Agents.BaseAgentConfig{} = init(client, @unpinned)
  end

  test "passes with a custom catalog (it may work with any client)" do
    behaviours = %{@unpinned | model_catalog: {CustomCatalog, []}}
    assert %Normandy.Agents.BaseAgentConfig{} = init(%OtherClient{}, behaviours)
  end

  describe "ClaudioAdapter client options" do
    alias Normandy.LLM.ClaudioAdapter

    test "init raises at configuration time for an invalid options combination" do
      client = %ClaudioAdapter{
        api_key: "sk-secret",
        options: %{thinking: :adaptive, thinking_budget: 1024}
      }

      error = assert_raise ArgumentError, fn -> init(client, nil) end
      assert error.message =~ "mutually exclusive"
      refute error.message =~ "sk-secret"
    end

    test "init accepts valid ClaudioAdapter options and ignores non-Claudio clients" do
      assert %{} = init(%ClaudioAdapter{api_key: "k", options: %{effort: :high}}, @pinned)
      assert %{} = init(%OtherClient{}, nil)
    end
  end

  defmodule HostCompactor do
    @behaviour Normandy.Behaviours.Compactor
    @impl true
    def maybe_compact(acc, _ctx, _opts), do: {acc, %{compacted: false}}
    @impl true
    def validate_opts!(opts, _entry) do
      if Keyword.has_key?(opts, :typo), do: raise(ArgumentError, "HostCompactor: no :typo")
      opts
    end

    @impl true
    def needs_window?(opts), do: Keyword.get(opts, :windowed, false)
  end

  test "a host compactor whose validate_opts!/2 raises fails at init" do
    behaviours = %Config{compactor: {HostCompactor, [typo: 1]}}

    assert_raise ArgumentError, "HostCompactor: no :typo", fn ->
      init(%OtherClient{}, behaviours)
    end
  end

  test "a host compactor's needs_window?/1 decides whether the catalog needs a Claudio client" do
    assert %Normandy.Agents.BaseAgentConfig{} =
             init(%OtherClient{}, %Config{compactor: {HostCompactor, []}})

    assert_raise ArgumentError, ~r/needs the model's context window/, fn ->
      init(%OtherClient{}, %Config{compactor: {HostCompactor, [windowed: true]}})
    end
  end
end
