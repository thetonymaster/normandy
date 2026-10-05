defmodule Normandy.Agents.BaseAgentMaxTokensTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig, ConfigTemplate}

  defmodule CapturingClient do
    defstruct [:pid]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.pid, {:max_tokens, request.max_tokens})
        response_model = request.response_model

        content =
          if Map.has_key?(response_model, :chat_message),
            do: %{response_model | chat_message: "ok"},
            else: response_model

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
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
    BaseAgent.run!(init(), %{chat_message: "hi"})
    assert_receive {:max_tokens, 16_000}
  end

  test "an explicit :max_tokens is kept" do
    assert init(%{max_tokens: 2048}).max_tokens == 2048
  end

  test "an explicit nil or non-positive :max_tokens raises with the expected type" do
    for bad <- [nil, 0, -1, "4096"] do
      assert_raise ArgumentError,
                   ~r/:max_tokens option: expected a positive integer \(the Messages API requires it\), got: #{Regex.escape(inspect(bad))}/,
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
    agent = DefaultDSLAgent.new(client: %CapturingClient{pid: self()})
    assert agent.max_tokens == 16_000
  end
end
