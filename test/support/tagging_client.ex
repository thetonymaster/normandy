defmodule Normandy.Test.TaggingClient do
  @moduledoc """
  A model client that answers `"<name>(<last message>)"`, so a test can see
  which agent ran and what it received. With `:fail_on`, it raises when the
  last message contains that text. With `:sleep_ms`, it sleeps first.
  """
  use Normandy.Schema

  schema do
    field(:name, :string)
    field(:fail_on, :string)
    field(:sleep_ms, :integer, default: 0)
  end

  defimpl Normandy.Agents.Model do
    def converse(client, request, _opts) do
      text = to_text(List.last(request.messages).content)
      if client.sleep_ms > 0, do: Process.sleep(client.sleep_ms)
      if client.fail_on && text =~ client.fail_on, do: raise("#{client.name} failed")

      {:ok,
       %Normandy.LLM.Response{
         content: %{request.response_model | chat_message: "#{client.name}(#{text})"}
       }}
    end

    def stream(_client, _request, _opts),
      do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}

    defp to_text(content) when is_binary(content), do: content
    defp to_text(content), do: inspect(content)
  end
end
