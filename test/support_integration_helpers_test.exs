defmodule NormandyTest.Support.IntegrationHelpersTest do
  # Serial: sets ANTHROPIC_API_KEY, which is process-global, for the helpers to read.
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias NormandyTest.Support.{IntegrationHelper, NormandyIntegrationHelper}

  setup do
    previous = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-test-not-used")

    on_exit(fn ->
      if previous,
        do: System.put_env("ANTHROPIC_API_KEY", previous),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)
  end

  test "IntegrationHelper's real client passes BaseAgent.init's option validation" do
    client = IntegrationHelper.create_real_client()
    assert %Normandy.Agents.BaseAgentConfig{} = BaseAgent.init(%{client: client, model: "m"})
  end

  test "NormandyIntegrationHelper's real client passes BaseAgent.init's option validation" do
    client = NormandyIntegrationHelper.create_real_client()
    assert %Normandy.Agents.BaseAgentConfig{} = BaseAgent.init(%{client: client, model: "m"})
  end
end
