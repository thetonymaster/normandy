defmodule Normandy.Components.DateTimeProvider do
  @moduledoc """
  Context provider that supplies current date and time information to agents.

  This provider can be registered with an agent to automatically include
  current date/time information in the system prompt.

  ## Example

      # Create a provider instance
      provider = %Normandy.Components.DateTimeProvider{}

      # Register with an agent
      agent = BaseAgent.register_context_provider(agent, "datetime", provider)

  The provider will add a section to the system prompt like:

      ## Current Date and Time
      2025-10-27 15:30:45.123456Z
  """

  @type t :: %__MODULE__{}

  defstruct []

  defimpl Normandy.Components.ContextProvider do
    @doc """
    Returns the title for the date/time context section.
    """
    def title(_provider) do
      "Current Date and Time"
    end

    @doc """
    Returns the current UTC date and time as a string.
    """
    def get_info(_provider) do
      DateTime.utc_now()
      |> DateTime.to_string()
    end
  end
end
