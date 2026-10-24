defmodule Normandy.Agents.Turn.Start do
  @moduledoc false

  # Start the server, tolerating Horde's eventually-consistent `:via` registration.
  # Two race shapes surface (and each supervisor nests them differently):
  #   * `{:already_started, pid}` — a concurrent caller won; route to that pid.
  #   * `{:process_not_registered_via, _}` — the via registration was not resolvable
  #     at start time (a concurrent winner mid-registration, OR a registry that has
  #     not converged yet), or `:registration_race` — a self-registering server found
  #     the session taken by a server that then died. Route to the winner if one is
  #     now visible, else retry the start briefly. Genuine errors propagate unchanged.
  def start_server(
        sup_mod,
        sup,
        server_opts,
        registry,
        sid,
        retries \\ 20
      ) do
    case sup_mod.start_server(sup, server_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        cond do
          pid = already_started_pid(reason) ->
            {:ok, pid}

          via_race?(reason) and retries > 0 ->
            route_or_retry({sup_mod, sup, server_opts}, registry, sid, retries)

          true ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  # A via race: route to the winner if the registry shows one, else start again after
  # a short wait.
  defp route_or_retry({sup_mod, sup, server_opts}, {reg_mod, reg_handle} = registry, sid, retries) do
    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} ->
        {:ok, pid}

      :none ->
        Process.sleep(10)
        start_server(sup_mod, sup, server_opts, registry, sid, retries - 1)

      {:error, lookup_error} ->
        {:error, lookup_error}
    end
  end

  # Extract the winner pid from either the bare or supervisor-nested already-started shape.
  defp already_started_pid({:already_started, pid}), do: pid
  defp already_started_pid({{:already_started, pid}, _child}), do: pid
  defp already_started_pid(_), do: nil

  # Recognize the via-not-registered race in either the bare or nested shape, and a
  # self-registering server's :registration_race (the session's registered server died
  # between that start's register/3 and its whereis/2).
  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(:registration_race), do: true
  defp via_race?({:registration_race, _child}), do: true
  defp via_race?(_), do: false
end
