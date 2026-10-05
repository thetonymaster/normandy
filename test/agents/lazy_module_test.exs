defmodule Normandy.Agents.LazyModuleTest do
  # async: false — unloading a module is VM-global.
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgentConfig, ValidationMiddleware}
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.{LazyInput, LazyTool, LazyViaRegistry}
  alias Normandy.Tools.Input

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

  test "Input.validate validates a tool whose module is not loaded yet" do
    tool = unloaded_struct(LazyTool, %{})

    assert {:error, [%{constraint: :enum}]} =
             Input.validate(tool, %{"operation" => "bogus"})
  end

  test "Turn.Supervisor and Turn.Server load a registry module before checking child_name/2" do
    registry = :"lazy_via_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    {:ok, sup} = Turn.Supervisor.start_link([])

    _ = unloaded_struct(LazyViaRegistry, %{})

    # Unloaded, child_name/2 looked missing: the server started without its :via
    # name and registered itself, which this registry refuses.
    assert {:ok, pid} =
             Turn.Supervisor.start_server(sup,
               session_id: "lazy",
               config: nil,
               store: {InMemory, InMemory.new()},
               registry: {LazyViaRegistry, registry}
             )

    assert {:ok, ^pid} = LazyViaRegistry.whereis(registry, "lazy")
  end

  test "ValidationMiddleware validates against an input schema whose module is not loaded yet" do
    schema = unloaded_struct(LazyInput, %{query: nil})

    assert {:error, _} =
             ValidationMiddleware.validate_input(%BaseAgentConfig{input_schema: schema}, %{
               other: 1
             })
  end
end
