defmodule Normandy.Test.LazyViaRegistry do
  @moduledoc """
  A SessionRegistry that names servers with a `:via` tuple (over an Elixir
  Registry whose name is the handle). Tests unload it to check that callers load
  a registry module before asking whether it exports `child_name/2`.
  """

  def child_name(registry, sid), do: {:via, Registry, {registry, sid}}

  def whereis(registry, sid) do
    case Registry.lookup(registry, sid) do
      [{pid, _}] -> {:ok, pid}
      [] -> :none
    end
  end

  # A server started under a :via name is registered by the name; it must never
  # register itself as well.
  def register(_registry, _sid, _pid), do: raise("a :via-named server registered itself")
  def unregister(_registry, _sid), do: :ok
end
