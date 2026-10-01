defmodule Normandy.Agents.Turn.Session do
  @moduledoc """
  Router in front of `Turn.Server`. Resolves `session_id` to a live pid via the
  `SessionRegistry`; on a miss, starts a `Turn.Server` under `Turn.Supervisor` with
  the **caller-supplied** config (the store never holds config/credentials). The
  server loads its turn state and conversation memory from the `SessionStore` on
  every start, so a supervisor restart resumes from the store, not from the
  state captured when the session first started.

  ## Tier-2 thin start (when `opts[:template_provider]` is set)

  The caller supplies a full `:config` AND a `:template_provider`. On first start,
  `rehydrate_and_start/1` persists a secret-free `ConfigTemplate` derived from the
  config, then launches `Turn.Server` with **thin** opts (no `:config`). The server
  reconstructs the full config node-locally from the stored template + supplement +
  credential token. On subsequent starts (after passivation), the server finds the
  persisted template in the store and reconstructs without any caller-supplied
  config.

  A caller may also pass only `:template_provider` (no `:config`), for example on
  a surviving node after the session's node died: the server starts from the
  template already saved in the store. With no saved template, `run/2` returns
  `{:error, {:no_config_template, session_id}}`.

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
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn.{Server, Supervisor}

  # Plain-data server options saved with a Tier-2 template, so a server started
  # without them (e.g. by ResumeReaper) restores them. Functions (:subscriber,
  # :handlers) cannot be stored; the starter must pass those.
  @stored_server_options [:approval_timeout_ms, :on_approval_timeout, :idle_timeout_ms]

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

  # Turn.Server.init/1 loads the turn state and rebuilds memory from the store
  # itself (on every start, including supervisor restarts), so the server opts
  # carry only the caller's config and options. A store fault in that load
  # comes back as the start's {:error, reason}.
  defp rehydrate_and_start(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    supervisor = Keyword.fetch!(opts, :supervisor)
    supervisor_mod = Keyword.get(opts, :supervisor_mod, Supervisor)
    {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)

    with {:ok, server_opts} <- server_opts(opts) do
      start_with_retry(supervisor_mod, supervisor, server_opts, reg_mod, reg_handle, sid)
    end
  end

  # Three ways to start: a :config with no template provider (Tier 0/1); a :config
  # with a template provider, which saves the template first (Tier 2, first
  # start); or a template provider alone, which starts from the template already
  # in the store (Tier 2, e.g. a caller on a surviving node that has no config).
  defp server_opts(opts) do
    case {Keyword.fetch(opts, :config), Keyword.get(opts, :template_provider)} do
      {{:ok, config}, nil} ->
        {:ok,
         opts
         |> base_server_opts()
         |> Keyword.put(:config, config)}

      {{:ok, config}, _provider} ->
        :ok = save_template(opts, config)
        {:ok, thin_server_opts(opts)}

      {:error, _provider} ->
        if template_saved?(opts) do
          {:ok, thin_server_opts(opts)}
        else
          {:error, {:no_config_template, Keyword.fetch!(opts, :session_id)}}
        end
    end
  end

  defp save_template(opts, config) do
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)

    tmpl =
      config
      |> ConfigTemplate.from_config(template_id_of(opts, config))
      |> Map.put(:server_options, Map.new(Keyword.take(opts, @stored_server_options)))

    store_mod.save_config_template(store_handle, Keyword.fetch!(opts, :session_id), tmpl)
  end

  defp template_saved?(opts) do
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)

    match?(
      {:ok, _},
      store_mod.load_config_template(store_handle, Keyword.fetch!(opts, :session_id))
    )
  end

  defp base_server_opts(opts) do
    opts
    |> Keyword.take([:session_id, :store, :registry, :subscriber, :handlers])
    |> Keyword.merge(Keyword.take(opts, @stored_server_options))
  end

  defp thin_server_opts(opts) do
    opts
    |> base_server_opts()
    |> Keyword.put(:template_provider, Keyword.fetch!(opts, :template_provider))
    |> Keyword.put(:resume_policy, Keyword.get(opts, :resume_policy, :lazy))
  end

  # Start the server, tolerating Horde's eventually-consistent `:via` registration.
  # Two race shapes surface (and each supervisor nests them differently):
  #   * `{:already_started, pid}` — a concurrent caller won; route to that pid.
  #   * `{:process_not_registered_via, _}` — the via registration was not resolvable
  #     at start time (a concurrent winner mid-registration, OR a registry that has
  #     not converged yet). Route to the winner if one is now visible, else retry the
  #     start briefly. Genuine errors propagate unchanged.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp start_with_retry(sup_mod, sup, server_opts, reg_mod, reg_handle, sid, retries \\ 20) do
    case sup_mod.start_server(sup, server_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        cond do
          pid = already_started_pid(reason) ->
            {:ok, pid}

          via_race?(reason) and retries > 0 ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case reg_mod.whereis(reg_handle, sid) do
              {:ok, pid} ->
                {:ok, pid}

              :none ->
                Process.sleep(10)
                start_with_retry(sup_mod, sup, server_opts, reg_mod, reg_handle, sid, retries - 1)
            end

          true ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  # Extract the winner pid from either the bare or supervisor-nested already-started shape.
  defp already_started_pid({:already_started, pid}), do: pid
  defp already_started_pid({{:already_started, pid}, _child}), do: pid
  defp already_started_pid(_), do: nil

  # Recognize the via-not-registered race in either the bare or nested shape.
  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(_), do: false

  defp template_id_of(opts, config),
    do: Keyword.get(opts, :template_id) || config.name || "default"
end
