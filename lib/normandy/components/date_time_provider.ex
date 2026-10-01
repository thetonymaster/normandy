defmodule Normandy.Components.DateTimeProvider do
  @moduledoc """
  Context provider that supplies today's UTC date to agents.

  This provider can be registered with an agent to automatically include
  the current date in the system prompt. It reports the date, not the time: a
  value that changes on every call would invalidate the prompt cache from the
  system prompt onwards.

  ## Example

      # Create a provider instance
      provider = %Normandy.Components.DateTimeProvider{}

      # Register with an agent
      agent = BaseAgent.register_context_provider(agent, "datetime", provider)

  The provider will add a section to the system prompt like:

      ## Current Date
      2026-09-30
  """

  @type t :: %__MODULE__{}

  defstruct []

  defimpl Normandy.Components.ContextProvider do
    @doc """
    Returns the title for the date context section.
    """
    def title(_provider) do
      "Current Date"
    end

    @doc """
    Returns today's UTC date (ISO 8601). Date only: the text changes once a day,
    so the system prompt stays a stable, cacheable prefix.
    """
    def get_info(_provider) do
      Date.utc_today() |> Date.to_iso8601()
    end
  end
end
