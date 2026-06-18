defmodule Normandy.Test.StubCreds do
  @moduledoc "Stub CredentialProvider that returns a fixed test token."
  @behaviour Normandy.Behaviours.CredentialProvider
  @impl true
  def get_token(_provider, _opts), do: {:ok, "TEST-TOKEN"}
end

defmodule Normandy.Test.TurnConfig do
  @moduledoc """
  Shared test helper: builds a reconstructable `%BaseAgentConfig{}` used across
  Turn.Server, Turn.Supervisor.Horde, and related tests.
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.PromptSpecification

  defmodule Resp do
    @moduledoc false
    defstruct content: "", tool_calls: nil
  end

  @spec build() :: Normandy.Agents.BaseAgentConfig.t()
  def build do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      model: "test",
      client: %{api_key: "k"},
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{},
      tool_registry: Normandy.Tools.Registry.new(),
      behaviours: %Normandy.Behaviours.Config{
        credential: {Normandy.Test.StubCreds, []}
      }
    }
  end
end
