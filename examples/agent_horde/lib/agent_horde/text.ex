defmodule AgentHorde.Text do
  @moduledoc """
  Extracts prose text from an agent response value.

  Mirrors `CustomerSupport.ChatSession.extract_response_text/1`.
  """

  @doc """
  Converts an agent response to a plain string.

  - Binary → returned as-is.
  - Map with `:chat_message` → the chat message value.
  - Map with `:content` list → text blocks joined with newlines.
  - Anything else → `inspect/1`.
  """
  def of(response) when is_binary(response), do: response

  def of(response) when is_map(response) do
    cond do
      Map.has_key?(response, :chat_message) ->
        response.chat_message

      Map.has_key?(response, :content) and is_list(response.content) ->
        response.content
        |> Enum.map(&extract_block/1)
        |> Enum.join("\n")

      true ->
        inspect(response)
    end
  end

  def of(response), do: inspect(response)

  defp extract_block(%{text: text}), do: text
  defp extract_block(%{type: "text", text: text}), do: text
  defp extract_block(_), do: ""
end
