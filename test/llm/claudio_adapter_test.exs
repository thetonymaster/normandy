defmodule NormandyTest.LLM.ClaudioAdapterTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Agents.BaseAgentOutputSchema

  describe "ClaudioAdapter schema" do
    test "creates adapter with required fields" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{timeout: 60_000}
      }

      assert adapter.api_key == "test-key"
      assert adapter.options.timeout == 60_000
      assert adapter.base_url == nil
    end

    test "creates adapter with custom base_url" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        base_url: "https://custom.api.com"
      }

      assert adapter.base_url == "https://custom.api.com"
    end
  end

  describe "Model protocol implementation" do
    test "implements completitions/6 (legacy compatibility)" do
      adapter = %ClaudioAdapter{api_key: "test-key"}
      response_model = %BaseAgentOutputSchema{}

      result =
        Normandy.Agents.Model.completitions(
          adapter,
          "claude-3",
          0.7,
          1024,
          "test",
          response_model
        )

      # Should return the response_model unchanged for legacy API
      assert result == response_model
    end

    # Note: Testing actual converse/7 would require mocking Claudio.Client
    # and Claudio.Messages.create, which is beyond this basic test.
    # In integration tests, you would mock these dependencies.
  end

  describe "ClaudioAdapter integration" do
    test "can be used as a client in BaseAgent config" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{
          timeout: 60_000,
          enable_caching: true
        }
      }

      config = %{
        client: adapter,
        model: "claude-3-5-sonnet-20241022",
        temperature: 0.7
      }

      agent = Normandy.Agents.BaseAgent.init(config)

      assert agent.client == adapter
      assert agent.model == "claude-3-5-sonnet-20241022"
      assert agent.temperature == 0.7
    end
  end
end
