defmodule Normandy.Agents.BaseAgentMaxTokensTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate}

  defmodule CapturingClient do
    defstruct [:pid]

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(client, _model, _temperature, max_tokens, _messages, response_model, _opts) do
        send(client.pid, {:max_tokens, max_tokens})

        if Map.has_key?(response_model, :chat_message),
          do: %{response_model | chat_message: "ok"},
          else: response_model
      end
    end
  end

  defp init(extra \\ %{}) do
    BaseAgent.init(Map.merge(%{client: %CapturingClient{pid: self()}, model: "m"}, extra))
  end

  test "default_max_tokens/0 is 16_000" do
    assert BaseAgentConfig.default_max_tokens() == 16_000
  end

  test "init/1 without :max_tokens uses the default" do
    assert init().max_tokens == 16_000
  end

  test "the default reaches the client on run/2" do
    BaseAgent.run(init(), %{chat_message: "hi"})
    assert_receive {:max_tokens, 16_000}
  end

  test "an explicit :max_tokens is kept" do
    assert init(%{max_tokens: 2048}).max_tokens == 2048
  end

  test "an explicit nil or non-positive :max_tokens raises with the expected type" do
    for bad <- [nil, 0, -1, "4096"] do
      assert_raise ArgumentError,
                   ~r/:max_tokens must be a positive integer.*got: #{Regex.escape(inspect(bad))}/,
                   fn ->
                     init(%{max_tokens: bad})
                   end
    end
  end

  test "a 1.x template with max_tokens: nil rebuilds with the default" do
    config = init(%{max_tokens: 100})

    supp = %{
      tool_registry: %Normandy.Tools.Registry{tools: %{}},
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> %CapturingClient{pid: self()} end
    }

    tmpl = config |> ConfigTemplate.from_config("t") |> Map.put(:max_tokens, nil)

    assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").max_tokens == 16_000
  end

  defmodule DefaultDSLAgent do
    use Normandy.DSL.Agent

    agent do
      model("m")
    end
  end

  test "a DSL agent without max_tokens uses the same default" do
    {:ok, agent} = DefaultDSLAgent.new(client: %CapturingClient{pid: self()})
    assert agent.max_tokens == 16_000
  end
end
