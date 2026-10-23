defmodule Normandy.Coordination.StatefulContext do
  @moduledoc """
  GenServer-backed shared context for multi-agent systems.

  StatefulContext provides a concurrent, process-based key-value store
  using GenServer with ETS backing.

  ## Features

  - Concurrent access from multiple processes
  - Reads from ETS: each read makes one short `GenServer.call` for the table, then
    looks the key up in ETS. The context process does only short work (an insert, a
    delete, a notification), so a read waits behind at most that; `update/4` runs
    its function in the caller, never in the context process
  - Atomic updates: the table is `:protected`, so only the context process writes it;
    `update/4` commits with a compare-and-set (see there)
  - Optional pub/sub notifications for changes
  - Process supervision compatible

  ## Example

      # Start context process
      {:ok, pid} = StatefulContext.start_link(name: :my_context)

      # Store and retrieve data
      :ok = StatefulContext.put(pid, "key", "value")
      {:ok, "value"} = StatefulContext.fetch(pid, "key")

      # Use namespaced keys
      :ok = StatefulContext.put(pid, {"agent_1", "status"}, "active")

      # Subscribe to changes
      :ok = StatefulContext.subscribe(pid, self())
  """

  use GenServer

  alias Normandy.Coordination.SharedContext
  alias Normandy.Options

  @type key :: String.t() | {String.t(), String.t()}
  @type subscriber :: pid()

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the context."],
                            notify_on_change: [
                              type: :boolean,
                              default: true,
                              doc: "Send subscribers a message on every change."
                            ]
                          )

  # Lost compare-and-sets after which update/4 runs its function in the context process.
  @max_conflicts 10

  # Client API

  @doc """
  Starts a StatefulContext GenServer.

  ## Options

  #{Options.docs(@start_link_opts_schema)}

  ## Example

      {:ok, pid} = StatefulContext.start_link(name: :shared_context)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stores a value in the context.

  Writes go through the context process for consistency; reads look the key up
  in ETS (after one short call for the table).

  ## Example

      :ok = StatefulContext.put(pid, "key", "value")
      :ok = StatefulContext.put(pid, {"agent_1", "data"}, %{result: 42})
  """
  @spec put(GenServer.server(), key(), term()) :: :ok
  def put(server, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  @doc """
  Looks up `key`: `{:ok, value}` or `:error`.

  Asks the context process for its table (one short `GenServer.call`), then reads
  the key from ETS.

  ## Example

      {:ok, value} = StatefulContext.fetch(pid, "key")
      :error = StatefulContext.fetch(pid, "missing")
  """
  @spec fetch(GenServer.server(), key()) :: {:ok, term()} | :error
  def fetch(server, key) do
    table = get_table(server)
    normalized_key = normalize_key(key)

    case :ets.lookup(table, normalized_key) do
      [{^normalized_key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Retrieves a value with a default if not found.

  ## Example

      value = StatefulContext.get(pid, "key", "default")
  """
  @spec get(GenServer.server(), key(), term()) :: term()
  def get(server, key, default) do
    case fetch(server, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Checks if a key exists in the context.

  ## Example

      true = StatefulContext.has_key?(pid, "key")
  """
  @spec has_key?(GenServer.server(), key()) :: boolean()
  def has_key?(server, key) do
    table = get_table(server)
    normalized_key = normalize_key(key)
    :ets.member(table, normalized_key)
  end

  @doc """
  Deletes a key from the context.

  ## Example

      :ok = StatefulContext.delete(pid, "key")
  """
  @spec delete(GenServer.server(), key()) :: :ok
  def delete(server, key) do
    GenServer.call(server, {:delete, key})
  end

  @doc """
  Returns all keys in the context.

  ## Example

      keys = StatefulContext.keys(pid)
      #=> ["key1", "agent_1:status"]
  """
  @spec keys(GenServer.server()) :: [String.t()]
  def keys(server) do
    table = get_table(server)

    :ets.tab2list(table)
    |> Enum.map(fn {key, _value} -> key end)
  end

  @doc """
  Updates a value using a function.

  If the key doesn't exist, uses the initial value.

  `fun` runs in the calling process, not in the context process, so a slow `fun`
  blocks no other caller and a `fun` that raises raises in the caller. The result
  is committed only if the key still holds the value `fun` was given; otherwise
  `fun` runs again on the new value. So `fun` can run more than once and must have
  no side effects. After #{@max_conflicts} lost races (a key written more often than
  `fun` takes) `fun` runs once inside the context process, serialized with every other
  call, so every update finishes; a `fun` that raises there crashes the context.

  The caller reads the key from ETS directly (`get_table/1`), so `update/4` works only
  against a context on the caller's node.

  ## Example

      :ok = StatefulContext.update(pid, "counter", 0, fn count -> count + 1 end)
  """
  @spec update(GenServer.server(), key(), term(), (term() -> term())) :: :ok
  def update(server, key, initial, fun), do: update(server, key, initial, fun, @max_conflicts)

  defp update(server, key, initial, fun, 0),
    do: GenServer.call(server, {:update, key, initial, fun}, :infinity)

  defp update(server, key, initial, fun, retries) do
    table = get_table(server)
    normalized_key = normalize_key(key)

    {expected, current} =
      case :ets.lookup(table, normalized_key) do
        [{^normalized_key, value}] -> {{:ok, value}, value}
        [] -> {:none, initial}
      end

    new_value = fun.(current)

    case GenServer.call(server, {:compare_and_put, normalized_key, expected, initial, new_value}) do
      :ok -> :ok
      :conflict -> update(server, key, initial, fun, retries - 1)
    end
  end

  @doc """
  Returns all data in the context as a map.

  ## Example

      data = StatefulContext.to_map(pid)
      #=> %{"key1" => "value1", "agent_1:status" => "active"}
  """
  @spec to_map(GenServer.server()) :: map()
  def to_map(server) do
    table = get_table(server)

    :ets.tab2list(table)
    |> Map.new()
  end

  @doc """
  Subscribes a process to change notifications.

  The subscriber will receive messages of the form:
  `{:context_changed, key, old_value, new_value}`

  ## Example

      :ok = StatefulContext.subscribe(pid, self())
  """
  @spec subscribe(GenServer.server(), subscriber()) :: :ok
  def subscribe(server, subscriber_pid) do
    GenServer.call(server, {:subscribe, subscriber_pid})
  end

  @doc """
  Unsubscribes a process from change notifications.

  ## Example

      :ok = StatefulContext.unsubscribe(pid, self())
  """
  @spec unsubscribe(GenServer.server(), subscriber()) :: :ok
  def unsubscribe(server, subscriber_pid) do
    GenServer.call(server, {:unsubscribe, subscriber_pid})
  end

  @doc """
  Returns the ETS table, for reads (`:ets.lookup/2`, `:ets.select/2`, ...).

  The table is `:protected`: only the context process writes it, so a write from
  any other process raises `ArgumentError`. Write through `put/3`, `update/4` and
  `delete/2`.

  ## Example

      table = StatefulContext.get_table(pid)
      :ets.lookup(table, "key")
  """
  @spec get_table(GenServer.server()) :: :ets.tid()
  def get_table(server) do
    GenServer.call(server, :get_table)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    notify_on_change = Keyword.fetch!(opts, :notify_on_change)

    # Create ETS table for data storage
    table =
      :ets.new(:stateful_context, [
        :set,
        :protected,
        read_concurrency: true,
        write_concurrency: false
      ])

    state = %{
      table: table,
      subscribers: MapSet.new(),
      notify_on_change: notify_on_change,
      created_at: :os.system_time(:second),
      updated_at: :os.system_time(:second)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    normalized_key = normalize_key(key)

    # Get old value for notifications
    old_value =
      case :ets.lookup(state.table, normalized_key) do
        [{^normalized_key, val}] -> {:ok, val}
        [] -> {:error, :not_found}
      end

    # Write to ETS
    :ets.insert(state.table, {normalized_key, value})

    # Notify subscribers if enabled
    if state.notify_on_change do
      notify_subscribers(state.subscribers, normalized_key, old_value, value)
    end

    updated_state = %{state | updated_at: :os.system_time(:second)}
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    normalized_key = normalize_key(key)

    # Get old value for notifications
    old_value =
      case :ets.lookup(state.table, normalized_key) do
        [{^normalized_key, val}] -> {:ok, val}
        [] -> {:error, :not_found}
      end

    # Delete from ETS
    :ets.delete(state.table, normalized_key)

    # Notify subscribers if enabled
    if state.notify_on_change do
      notify_subscribers(state.subscribers, normalized_key, old_value, :deleted)
    end

    updated_state = %{state | updated_at: :os.system_time(:second)}
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:compare_and_put, key, expected, initial, new_value}, _from, state) do
    actual =
      case :ets.lookup(state.table, key) do
        [{^key, val}] -> {:ok, val}
        [] -> :none
      end

    if actual === expected do
      old_value =
        case expected do
          {:ok, val} -> val
          :none -> initial
        end

      {:reply, :ok, commit(state, key, old_value, new_value)}
    else
      {:reply, :conflict, state}
    end
  end

  # update/4's last resort: the function runs here, serialized with every other call.
  @impl true
  def handle_call({:update, key, initial, fun}, _from, state) do
    normalized_key = normalize_key(key)

    current =
      case :ets.lookup(state.table, normalized_key) do
        [{^normalized_key, val}] -> val
        [] -> initial
      end

    {:reply, :ok, commit(state, normalized_key, current, fun.(current))}
  end

  @impl true
  def handle_call({:subscribe, subscriber_pid}, _from, state) do
    updated_subscribers = MapSet.put(state.subscribers, subscriber_pid)
    {:reply, :ok, %{state | subscribers: updated_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, subscriber_pid}, _from, state) do
    updated_subscribers = MapSet.delete(state.subscribers, subscriber_pid)
    {:reply, :ok, %{state | subscribers: updated_subscribers}}
  end

  @impl true
  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up ETS table
    :ets.delete(state.table)
    :ok
  end

  # Private Functions

  defp commit(state, key, old_value, new_value) do
    :ets.insert(state.table, {key, new_value})

    if state.notify_on_change do
      notify_subscribers(state.subscribers, key, {:ok, old_value}, new_value)
    end

    %{state | updated_at: :os.system_time(:second)}
  end

  defp normalize_key(key), do: SharedContext.normalize_key(key)

  defp notify_subscribers(subscribers, key, old_value, new_value) do
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:context_changed, key, old_value, new_value})
    end)
  end
end
