defmodule Normandy.Agents.Turn.Session do
  @moduledoc """
  Router in front of `Turn.Server`. Resolves `session_id` to a live pid via the
  `SessionRegistry`; on a miss, rehydrates turn state + conversation memory from
  the `SessionStore` and starts a `Turn.Server` under `Turn.Supervisor` with the
  **caller-supplied** config (the store never holds config/credentials).

  ## Tier-2 thin start (when `opts[:template_provider]` is set)

  The caller supplies a full `:config` AND a `:template_provider`. On first start,
  `rehydrate_and_start/1` persists a secret-free `ConfigTemplate` derived from the
  config, then launches `Turn.Server` with **thin** opts (no `:config`). The server
  reconstructs the full config node-locally from the stored template + supplement +
  credential token. On subsequent starts (after passivation), the server finds the
  persisted template in the store and reconstructs without any caller-supplied
  config.

  ## Start-time race

  For `:self_register` (Native) registries the race between `whereis` returning
  `:none` and the new child finishing `register/3` is best-effort: a concurrent
  caller may start a second child, which then loses the race and keeps running
  unregistered. This was acceptable for single-router usage (Phase 4b).

  For via-based registries (Horde) the race is **closed**: the supervisor supplies
  a `:name` computed by `child_name/2`, so the OTP supervisor performs atomic
  registration at start. Any concurrent caller that loses the start race gets
  `{:error, {:already_started, pid}}`; `rehydrate_and_start/1` normalises this to
  `{:ok, pid}` so all callers converge on the single winner.
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
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)
    sid = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    supervisor = Keyword.fetch!(opts, :supervisor)
    supervisor_mod = Keyword.get(opts, :supervisor_mod, Supervisor)
    template_provider = Keyword.get(opts, :template_provider)
    resume_policy = Keyword.get(opts, :resume_policy, :lazy)

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
          if template_provider do
            tmpl =
              Normandy.Agents.ConfigTemplate.from_config(config, template_id_of(opts, config))

            :ok = store_mod.save_config_template(store_handle, sid, tmpl)

            opts
            |> Keyword.take([
              :session_id,
              :store,
              :registry,
              :subscriber,
              :handlers,
              :approval_timeout_ms,
              :idle_timeout_ms,
              :template_provider
            ])
            |> Keyword.put(:resume_policy, resume_policy)
            |> Keyword.put(:turn_state, turn_state)
          else
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
          end

        # Normalize the via-registry start-time race: when two callers both see
        # `:none` and race to start, the loser gets `{:already_started, pid}`.
        # Treat this as success — both callers converge on the single live server.
        case supervisor_mod.start_server(supervisor, server_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp template_id_of(opts, config),
    do: Keyword.get(opts, :template_id) || config.name || "default"
end
