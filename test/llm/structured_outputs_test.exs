defmodule Normandy.LLM.StructuredOutputsTest do
  use ExUnit.Case, async: false

  alias Normandy.LLM.StructuredOutputs
  alias Normandy.LLM.Json.TestFixtures.MultiField

  defmodule OpenMapSchema do
    use Normandy.Schema

    io_schema "schema with an open map" do
      field(:meta, :map, description: "open")
    end
  end

  defp client(opts \\ %{}), do: %Normandy.LLM.ClaudioAdapter{api_key: "k", options: opts}

  test "enabled? defaults to true" do
    assert StructuredOutputs.enabled?(client())
  end

  test "enabled? honors a per-client false override" do
    refute StructuredOutputs.enabled?(client(%{structured_outputs: false}))
  end

  test "schema_for returns {:ok, schema} for a compatible struct" do
    assert {:ok, schema} = StructuredOutputs.schema_for(client(), %MultiField{})
    assert schema["additionalProperties"] == false
    assert "chat_message" in Map.keys(schema["properties"])
  end

  test "schema_for skips when disabled per client" do
    assert :skip =
             StructuredOutputs.schema_for(client(%{structured_outputs: false}), %MultiField{})
  end

  test "schema_for skips an incompatible (open-map) schema" do
    assert :skip = StructuredOutputs.schema_for(client(), %OpenMapSchema{})
  end

  test "schema_for skips a non-struct response_model" do
    assert :skip = StructuredOutputs.schema_for(client(), %{})
  end
end
