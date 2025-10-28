defmodule Normandy.Coordination.AgentMessage do
  @moduledoc """
  Message structure for agent-to-agent communication.

  AgentMessage provides a standardized format for agents to communicate
  with each other, including metadata about the sender, message type,
  and payload.

  ## Example

      message = %AgentMessage{
        from: "research_agent",
        to: "writing_agent",
        type: :request,
        payload: %{query: "Find papers about AI"},
        metadata: %{priority: :high}
      }
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          __meta__: Normandy.Metadata.t(),
          id: String.t(),
          from: String.t(),
          to: String.t(),
          type: String.t(),
          payload: map(),
          metadata: map(),
          timestamp: integer()
        }

  schema do
    field(:id, :string, default: "")
    field(:from, :string, description: "Source agent identifier", required: true)
    field(:to, :string, description: "Destination agent identifier", required: true)
    field(:type, :string, description: "Message type", required: true)
    field(:payload, :map, description: "Message content", default: %{})
    field(:metadata, :map, description: "Additional metadata", default: %{})
    field(:timestamp, :integer, description: "Unix timestamp", default: 0)
  end

  @doc """
  Creates a new agent message.

  ## Options

  - `:from` - Source agent identifier (required)
  - `:to` - Destination agent identifier (required)
  - `:type` - Message type (`:request`, `:response`, `:broadcast`, `:error`)
  - `:payload` - Message content (map)
  - `:metadata` - Additional metadata (map)

  ## Example

      message = AgentMessage.new(
        from: "agent_1",
        to: "agent_2",
        type: :request,
        payload: %{task: "analyze data"}
      )
  """
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    %__MODULE__{
      id: UUID.uuid4(),
      from: Keyword.fetch!(opts, :from),
      to: Keyword.fetch!(opts, :to),
      type: Keyword.get(opts, :type, :request) |> to_string(),
      payload: Keyword.get(opts, :payload, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: :os.system_time(:second)
    }
  end

  @doc """
  Creates a response message to an original message.

  ## Example

      response = AgentMessage.reply(original_message, %{result: "success"})
  """
  @spec reply(%__MODULE__{}, map()) :: %__MODULE__{}
  def reply(%__MODULE__{from: original_from, to: original_to} = _original, payload) do
    new(
      from: original_to,
      to: original_from,
      type: :response,
      payload: payload
    )
  end

  @doc """
  Creates an error response message.

  ## Example

      error = AgentMessage.error(original_message, "Processing failed", %{code: 500})
  """
  @spec error(%__MODULE__{}, String.t(), map()) :: %__MODULE__{}
  def error(%__MODULE__{from: original_from, to: original_to}, reason, details \\ %{}) do
    new(
      from: original_to,
      to: original_from,
      type: :error,
      payload: %{error: reason, details: details}
    )
  end
end
