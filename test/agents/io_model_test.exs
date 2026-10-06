defmodule Normandy.Agents.IoModelTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentOutputSchema

  test "the default schemas tell the model what the message is (AX-26)" do
    assert %{
             description: "A chat message from the user.",
             properties: %{chat_message: %{description: "The user's message."}}
           } = BaseAgentInputSchema.__schema__(:specification)

    assert %{
             description: "Your reply to the user.",
             properties: %{
               chat_message: %{description: "Your reply to the user, in plain text or Markdown."}
             }
           } = BaseAgentOutputSchema.__schema__(:specification)
  end
end
