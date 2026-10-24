defmodule Normandy.Agents.BaseAgentInputSchema do
  @moduledoc """
  Default input schema for agent interactions.

  Provides a simple chat message input format.
  """

  use Normandy.Schema

  io_schema "A chat message from the user." do
    field(:chat_message, :string, description: "The user's message.")
  end
end

defmodule Normandy.Agents.BaseAgentOutputSchema do
  @moduledoc """
  Default output schema for agent responses.

  Provides a simple chat message output format.
  """

  use Normandy.Schema

  io_schema "Your reply to the user." do
    field(:chat_message, :string,
      description: "Your reply to the user, in plain text or Markdown."
    )
  end
end
