defmodule Normandy.LLM.ErrorMessageRedactionTest do
  @moduledoc """
  Error messages go to logs and crash reports, so they name what is wrong
  without copying user data (base64 payloads) or credentials (req_options).
  """
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Components.ContentBlock.{CacheControl, Document, Image}
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter

  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter
  @secret "SECRET-PAYLOAD-0123456789"

  defp message(fun) do
    assert_raise(ArgumentError, fun).message
  end

  test "an invalid base64 image names the problem and the data size, not the data" do
    msg =
      message(fn -> Image.to_claudio(%Image{source: :base64, data: @secret, media_type: nil}) end)

    refute msg =~ @secret
    assert msg =~ "#{byte_size(@secret)} bytes"
  end

  test "an invalid url image does not copy the block" do
    msg = message(fn -> Image.to_claudio(%Image{source: :url, url: "", data: @secret}) end)
    refute msg =~ @secret
  end

  test "an invalid document does not copy the block" do
    msg =
      message(fn ->
        Document.to_claudio(%Document{source: :base64, file_id: @secret})
      end)

    refute msg =~ @secret
  end

  test "a struct passed as cache_control is named by its type only" do
    msg = message(fn -> CacheControl.maybe_attach(%{}, %URI{host: @secret}) end)

    refute msg =~ @secret
    assert msg =~ "URI"
  end

  test "an unsupported content block is named by its type only" do
    msg =
      message(fn ->
        @impl_module.add_messages(
          Request.new("m"),
          [%Message{role: "user", content: [%URI{host: @secret}]}],
          false
        )
      end)

    refute msg =~ @secret
    assert msg =~ "URI"
  end

  test "malformed req_options do not print their value" do
    client = %ClaudioAdapter{
      api_key: "k",
      options: %{req_options: %{headers: [{"x-api-key", @secret}]}}
    }

    msg = message(fn -> ClaudioAdapter.to_claudio_client(client) end)

    refute msg =~ @secret
    assert msg =~ "a map"
  end
end
