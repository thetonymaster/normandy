defmodule Normandy.LLM.Json.SchemaBinderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaBinder
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RequiredField

  defmodule TextField do
    @moduledoc false
    use Normandy.Schema

    io_schema "a schema whose own field is named text" do
      field(:text, :string, description: "text", required: true)
    end
  end

  test "binds a bare map to the schema" do
    assert {:ok, %MultiField{chat_message: "hi", count: 2}} =
             SchemaBinder.bind(%{"chat_message" => "hi", "count" => 2}, %MultiField{}, "src")
  end

  test "normalizes response/message/text to chat_message" do
    assert {:ok, %MultiField{chat_message: "yo"}} =
             SchemaBinder.bind(%{"response" => "yo"}, %MultiField{}, "src")
  end

  test "keeps a field named text when the schema has one" do
    assert {:ok, %TextField{text: "hi"}} =
             SchemaBinder.bind(%{"text" => "hi"}, %TextField{}, "src")
  end

  test "an alias never overwrites a chat_message the payload already has" do
    assert {:ok, %MultiField{chat_message: "real"}} =
             SchemaBinder.bind(
               %{"chat_message" => "real", "text" => "other"},
               %MultiField{},
               "src"
             )
  end

  test "unwraps a tool-use arguments envelope" do
    assert {:ok, %MultiField{chat_message: "inner"}} =
             SchemaBinder.bind(
               %{"arguments" => %{"chat_message" => "inner"}},
               %MultiField{},
               "src"
             )
  end

  test "surfaces a validation error tuple when a required field is missing" do
    assert {:error, {:validation_error, _changeset, "src"}} =
             SchemaBinder.bind(%{"count" => 1}, %RequiredField{}, "src")
  end
end
