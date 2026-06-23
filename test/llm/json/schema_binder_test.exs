defmodule Normandy.LLM.Json.SchemaBinderTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.SchemaBinder
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RequiredField

  test "binds a bare map to the schema" do
    assert {:ok, %MultiField{chat_message: "hi", count: 2}} =
             SchemaBinder.bind(%{"chat_message" => "hi", "count" => 2}, %MultiField{}, "src")
  end

  test "normalizes response/message/text to chat_message" do
    assert {:ok, %MultiField{chat_message: "yo"}} =
             SchemaBinder.bind(%{"response" => "yo"}, %MultiField{}, "src")
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
