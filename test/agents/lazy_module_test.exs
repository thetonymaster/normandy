defmodule Normandy.Agents.LazyModuleTest do
  # async: false — unloading a module is VM-global.
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgentConfig, Dispatch, ValidationMiddleware}
  alias Normandy.Test.{LazyInput, LazyTool}

  # A struct can reach a node before its module is loaded there (e.g. a schema
  # struct in a Tier-2 template). Unload the module and build the struct as a
  # plain map, which does not load it.
  defp unloaded_struct(mod, fields) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
    refute :code.is_loaded(mod)
    Map.put(fields, :__struct__, mod)
  end

  test "Dispatch.validate_input validates a tool whose module is not loaded yet" do
    tool = unloaded_struct(LazyTool, %{operation: nil})

    assert {:error, [_ | _]} = Dispatch.validate_input(tool, %{"operation" => "bogus"})
  end

  test "ValidationMiddleware validates against an input schema whose module is not loaded yet" do
    schema = unloaded_struct(LazyInput, %{query: nil})

    assert {:error, _} =
             ValidationMiddleware.validate_input(%BaseAgentConfig{input_schema: schema}, %{
               other: 1
             })
  end
end
