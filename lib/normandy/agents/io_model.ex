defmodule Normandy.Agents.BaseAgentInputSchema do
  use Normandy.Schema
  @derive {Poison.Encoder, only: [:chat_message]}

  io_schema "base input" do
    field(:chat_message, :string, description: "an input chat message from user")
  end
end

defmodule Normandy.Agents.BaseAgentOutputSchema do
  use Normandy.Schema
  @derive {Poison.Encoder, only: [:chat_message]}

  io_schema "base output" do
    field(:chat_message, :string, description: "a result chat message")
  end
end
