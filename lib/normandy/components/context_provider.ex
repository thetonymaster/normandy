defprotocol Normandy.Components.ContextProvider do
  @moduledoc """
  Protocol for providing additional context information to agents.

  Context providers supply extra information that can be included in system prompts,
  such as current date/time, user preferences, system state, etc.

  ## Example

      defmodule DateTimeProvider do
        defstruct []

        defimpl Normandy.Components.ContextProvider do
          def title(_), do: "Current Date and Time"

          def get_info(_) do
            DateTime.utc_now() |> DateTime.to_string()
          end
        end
      end
  """

  @doc """
  Returns the title for this context section in the prompt.
  """
  @spec title(struct()) :: String.t()
  def title(context_config)

  @doc """
  Returns the context information as a string.
  """
  @spec get_info(struct()) :: String.t()
  def get_info(context_config)
end
