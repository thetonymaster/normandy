defmodule Normandy.Agents.BaseAgentInputSchema do
  @moduledoc """
  Default input schema for agent interactions.

  Provides a simple chat message input format.
  """

  use Normandy.Schema
  @derive {Poison.Encoder, only: [:chat_message]}

  io_schema "base input" do
    field(:chat_message, :string, description: "an input chat message from user")
  end
end

defmodule Normandy.Agents.BaseAgentOutputSchema do
  @moduledoc """
  Default output schema for agent responses.

  Provides a simple chat message output format.
  """

  use Normandy.Schema
  @derive {Poison.Encoder, only: [:chat_message]}

  io_schema "base output" do
    field(:chat_message, :string, description: "a result chat message")
  end
end
