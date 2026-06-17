defmodule Normandy.Agents.Turn.Session do
  @moduledoc """
  Router in front of `Turn.Server`. Resolves `session_id` to a live pid via the
  `SessionRegistry`; on a miss, rehydrates turn state + conversation memory from
  the `SessionStore` and starts a `Turn.Server` under `Turn.Supervisor` with the
  **caller-supplied** config (the store never holds config/credentials).
  """
  alias Normandy.Agents.Turn.{Server, Supervisor}
  alias Normandy.Components.AgentMemory

  @spec run(keyword(), term()) :: {:ok, term()} | {:error, term()}
  def run(opts, user_input) do
    with {:ok, pid} <- ensure_server(opts), do: Server.run(pid, user_input)
  end

  @spec approve(keyword(), map()) :: :ok | {:error, :no_session}
  def approve(opts, decisions) do
    {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} ->
        Server.approve(pid, decisions)

      # Approval only makes sense against a live, parked server. An
      # awaiting-approval server never passivates (only :idle does), so a
      # registry miss means there is no session to approve — fail closed
      # instead of booting a fresh server and silently dropping the approval.
      :none ->
        {:error, :no_session}
    end
  end

  defp ensure_server(opts) do
    {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} -> {:ok, pid}
      :none -> rehydrate_and_start(opts)
    end
  end

  defp rehydrate_and_start(opts) do
    # Race note: between `whereis` returning `:none` and the new child registering,
    # a concurrent caller could start a second child for the same `session_id`.
    # `Native.register/3` returns `{:error, :taken}` for the loser. For Phase 4b's
    # single-router usage this is acceptable; a `:via`-based start is the documented follow-up.
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)
    sid = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    supervisor = Keyword.fetch!(opts, :supervisor)

    turn_state =
      case store_mod.load_turn_state(store_handle, sid) do
        {:ok, term} -> term
        :error -> nil
      end

    # `history/2` may return a contract-permitted `{:error, _}` on a genuine
    # store fault; propagate it as run/2's error tuple instead of crashing.
    case store_mod.history(store_handle, sid) do
      {:ok, entries} ->
        # `from_entries/1` rebuilds with `max_messages: nil`; restore the caller's
        # configured cap so passivation/rehydration doesn't silently uncap memory.
        rebuilt_memory = %{
          AgentMemory.from_entries(entries)
          | max_messages: config.memory.max_messages
        }

        config = %{config | memory: rebuilt_memory}

        server_opts =
          opts
          |> Keyword.take([
            :session_id,
            :store,
            :registry,
            :subscriber,
            :handlers,
            :approval_timeout_ms,
            :idle_timeout_ms
          ])
          |> Keyword.put(:config, config)
          |> Keyword.put(:turn_state, turn_state)

        Supervisor.start_server(supervisor, server_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
