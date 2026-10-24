defmodule Bench.Repo do
  # The Postgres store handle for bench/session_store.exs and bench/memory_store.exs:
  # its own database (normandy_bench), never the test one.
  use Ecto.Repo, otp_app: :normandy, adapter: Ecto.Adapters.Postgres
end

defmodule Bench.StoreBackends do
  # Store handles for the store benchmarks (bench/README.md): which backends run
  # (BENCH_STORES), connecting them (an unreachable one raises, never skipped), and
  # deleting every session and namespace a run created.

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.SessionStore

  @backends [:in_memory, :ets, :mnesia, :redis, :postgres]
  @default_postgres "ecto://postgres:postgres@localhost:55432/normandy_bench"
  @default_redis "redis://localhost:6379"

  # The shipped migrations, at priv/test_repo/migrations' versions.
  @migrations [
    {20_260_617_000_000, SessionStore.Postgres.Migration},
    {20_260_617_000_100, SessionStore.Postgres.MigrationAddTemplate},
    {20_260_617_000_200, SessionStore.Postgres.MigrationAddResumePolicy},
    {20_261_003_000_000, MemoryStore.Postgres.Migration},
    {20_261_006_000_000, SessionStore.Postgres.MigrationAddInflight}
  ]

  for {version, shipped} <- @migrations do
    defmodule Module.concat(Bench.Migrations, "V#{version}") do
      use Ecto.Migration
      @shipped shipped
      def up, do: @shipped.up()
      def down, do: @shipped.down()
    end
  end

  @doc """
  The backends to run: all of them, or the BENCH_STORES list.

  Also traps exits in the calling script: a Benchee job that raises, or a Redis connect
  that fails, then exits the script through its `after` (cleanup!/0 runs) instead of
  killing it through the link.
  """
  @spec selected() :: [atom()]
  def selected do
    Process.flag(:trap_exit, true)

    case System.get_env("BENCH_STORES") do
      nil -> @backends
      list -> list |> String.split(",", trim: true) |> Enum.map(&backend!/1)
    end
  end

  @doc "`{store module, handle}` for a SessionStore on `backend`."
  @spec session_store(atom()) :: {module(), term()}
  def session_store(:in_memory), do: {SessionStore.InMemory, SessionStore.InMemory.new()}
  def session_store(:ets), do: {SessionStore.ETS, SessionStore.ETS.new()}

  def session_store(:mnesia) do
    mnesia_dir!()
    {SessionStore.Mnesia, SessionStore.Mnesia.new()}
  end

  def session_store(:redis) do
    url = reachable_redis!()

    {SessionStore.Redis,
     SessionStore.Redis.new(url: url, namespace: "normandy_bench:#{UUID.uuid4()}")}
  end

  def session_store(:postgres), do: {SessionStore.Postgres, repo!()}

  @doc "`{store module, handle}` for a MemoryStore on `backend`."
  @spec memory_store(atom()) :: {module(), term()}
  def memory_store(:in_memory), do: {MemoryStore.InMemory, MemoryStore.InMemory.new()}
  def memory_store(:ets), do: {MemoryStore.ETS, MemoryStore.ETS.new()}

  def memory_store(:mnesia) do
    mnesia_dir!()
    {MemoryStore.Mnesia, MemoryStore.Mnesia.new()}
  end

  def memory_store(:redis) do
    url = reachable_redis!()

    {MemoryStore.Redis,
     MemoryStore.Redis.new(url: url, prefix: "normandy_bench_mem:#{UUID.uuid4()}")}
  end

  def memory_store(:postgres), do: {MemoryStore.Postgres, repo!()}

  @doc "Remembers a session `cleanup!/0` deletes."
  @spec track_session({module(), term()}, String.t()) :: String.t()
  def track_session(store, id), do: track({:session, store, id}, id)

  @doc "Remembers a namespace `cleanup!/0` deletes."
  @spec track_namespace({module(), term()}, String.t()) :: String.t()
  def track_namespace(store, ns), do: track({:namespace, store, ns}, ns)

  @doc "Deletes every tracked session and namespace, then the Mnesia temp dir."
  @spec cleanup!() :: :ok
  def cleanup! do
    for item <- Process.get(:bench_tracked, []) do
      case item do
        {:session, {mod, h}, id} -> :ok = mod.delete_session(h, id)
        {:namespace, {mod, h}, ns} -> :ok = mod.delete_namespace(h, ns)
      end
    end

    Process.delete(:bench_tracked)

    with dir when is_binary(dir) <- Process.delete(:bench_mnesia_dir) do
      :stopped = :mnesia.stop()
      File.rm_rf!(dir)
    end

    :ok
  end

  defp track(item, id) do
    Process.put(:bench_tracked, [item | Process.get(:bench_tracked, [])])
    id
  end

  defp backend!(name) do
    case Enum.find(@backends, &(Atom.to_string(&1) == name)) do
      nil ->
        raise ArgumentError,
              "BENCH_STORES: unknown backend #{inspect(name)}; valid: #{Enum.join(@backends, ",")}"

      backend ->
        backend
    end
  end

  # Mnesia writes under its :dir; point it at a temp dir before it starts.
  defp mnesia_dir! do
    unless Process.get(:bench_mnesia_dir) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "normandy_bench_mnesia_#{System.unique_integer([:positive])}"
        )

      Application.put_env(:mnesia, :dir, String.to_charlist(dir))
      Process.put(:bench_mnesia_dir, dir)
    end
  end

  defp reachable_redis! do
    url = System.get_env("REDIS_URL", @default_redis)

    case Redix.start_link(url, sync_connect: true, exit_on_disconnection: false) do
      {:ok, conn} ->
        {:ok, "PONG"} = Redix.command(conn, ["PING"])
        :ok = Redix.stop(conn)
        url

      {:error, reason} ->
        unreachable!(:redis, url, reason)
    end
  end

  defp repo! do
    if Process.whereis(Bench.Repo) do
      Bench.Repo
    else
      url = System.get_env("POSTGRES_URL", @default_postgres)
      # storage_up/1 reads :database etc., not :url.
      config = Ecto.Repo.Supervisor.parse_url(url) ++ [pool_size: 2, log: false]

      case Ecto.Adapters.Postgres.storage_up(config) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, reason} -> unreachable!(:postgres, url, reason)
      end

      {:ok, _pid} = Bench.Repo.start_link(config)

      migrations =
        for {version, _} <- @migrations,
            do: {version, Module.concat(Bench.Migrations, "V#{version}")}

      Ecto.Migrator.run(Bench.Repo, migrations, :up, all: true, log: false)
      Bench.Repo
    end
  end

  defp unreachable!(backend, url, reason) do
    raise "#{backend} unreachable at #{redact(url)}: #{inspect(reason)}; " <>
            "set BENCH_STORES to leave it out"
  end

  # The URL without its userinfo (a password must not reach the console).
  defp redact(url), do: url |> URI.parse() |> Map.put(:userinfo, nil) |> URI.to_string()
end
