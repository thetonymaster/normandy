# Compiled only when Horde is available (an `optional` dep), like SessionRegistry.Horde.
if Code.ensure_loaded?(Horde.Registry) do
  defmodule Normandy.Behaviours.SessionRegistry.Horde.Via do
    @moduledoc false
    # `:via` callbacks for `SessionRegistry.Horde`. The name is the 2-tuple
    # `{registry, session_id}` that `SessionRegistry.Horde.child_name/2` builds to name a
    # `Turn.Server`; Horde's 3-tuple `{registry, key, value}` is not accepted (every
    # callback raises `FunctionClauseError` for it). Use `Horde.Registry` itself for a name
    # with a value.
    #
    # It exists because `Turn.Server` is a `:gen_statem`. After a `:via` registration,
    # OTP's `gen_statem` checks `whereis_name(name) == self()` before calling `init/1`
    # (`gen:get_proc_name/1`) and exits `{:process_not_registered_via, module}` otherwise
    # (`gen_server` makes no such check). `Horde.Registry`'s `register_name/2` answers
    # `:yes` before its `whereis_name/1` can see the key: the registry writes the key to its
    # ETS table only when it handles the `{:crdt_update, diffs}` message its CRDT sent
    # during the registration, after it has replied. A start whose check runs in that
    # window failed: 0.5–1.4% of sequential starts on one node, nearly every start
    # under 16 concurrent ones (measured on Horde 0.10.0).
    #
    # `register_name/2` therefore makes one synchronous call to the same registry
    # (`Horde.Cluster.members/1`) after a `:yes`. That call is queued behind the
    # `{:crdt_update, _}` message, so when it returns the key is in ETS and the check
    # passes. This depends on Horde's ordering (the CRDT sends `{:crdt_update, _}`
    # before it replies to the registry's put), verified against Horde 0.10.0; recheck
    # it when upgrading Horde. Every other callback delegates to `Horde.Registry`.

    @spec register_name({atom(), term()}, pid()) :: :yes | :no
    def register_name({registry, _key} = name, pid) do
      case Horde.Registry.register_name(name, pid) do
        :yes ->
          # A barrier: the registry handles this call after the key's :crdt_update.
          _members = Horde.Cluster.members(registry)
          :yes

        :no ->
          :no
      end
    end

    @spec whereis_name({atom(), term()}) :: pid() | :undefined
    def whereis_name({_registry, _key} = name), do: Horde.Registry.whereis_name(name)

    @spec unregister_name({atom(), term()}) :: :ok
    def unregister_name({_registry, _key} = name), do: Horde.Registry.unregister_name(name)

    @spec send({atom(), term()}, term()) :: term()
    def send({_registry, _key} = name, msg), do: Horde.Registry.send(name, msg)
  end
end
