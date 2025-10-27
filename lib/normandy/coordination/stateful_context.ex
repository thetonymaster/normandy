defmodule Normandy.Coordination.StatefulContext do
  @moduledoc """
  GenServer-backed shared context for multi-agent systems.

  StatefulContext provides a concurrent, process-based key-value store
  using GenServer with ETS backing for high-performance reads.

  ## Features

  - Concurrent access from multiple processes
  - Fast reads via ETS (no GenServer bottleneck)
  - Atomic updates via GenServer
  - Optional pub/sub notifications for changes
  - Process supervision compatible

  ## Example

      # Start context process
      {:ok, pid} = StatefulContext.start_link(name: :my_context)

      # Store and retrieve data
      :ok = StatefulContext.put(pid, "key", "value")
      {:ok, "value"} = StatefulContext.get(pid, "key")

      # Use namespaced keys
      :ok = StatefulContext.put(pid, {"agent_1", "status"}, "active")

      # Subscribe to changes
      :ok = StatefulContext.subscribe(pid, self())
  """

  use GenServer
  require Logger

  @type key :: String.t() | {String.t(), String.t()}
  @type subscriber :: pid()

  # Client API

  @doc """
  Starts a StatefulContext GenServer.

  ## Options

  - `:name` - Register the process with a name (optional)
  - `:notify_on_change` - Enable change notifications (default: true)

  ## Example

      {:ok, pid} = StatefulContext.start_link(name: :shared_context)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stores a value in the context.

  Writes go through GenServer for consistency, but subsequent reads
  are fast via ETS.

  ## Example

      :ok = StatefulContext.put(pid, "key", "value")
      :ok = StatefulContext.put(pid, {"agent_1", "data"}, %{result: 42})
  """
  @spec put(GenServer.server(), key(), term()) :: :ok
  def put(server, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  @doc """
  Retrieves a value from the context.

  Reads directly from ETS for maximum performance (no GenServer call).

  ## Example

      {:ok, value} = StatefulContext.get(pid, "key")
      {:error, :not_found} = StatefulContext.get(pid, "missing")
  """
  @spec get(GenServer.server(), key()) :: {:ok, term()} | {:error, :not_found}
  def get(server, key) do
    table = get_table(server)
    normalized_key = normalize_key(key)

    case :ets.lookup(table, normalized_key) do
      [{^normalized_key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Retrieves a value with a default if not found.

  ## Example

      value = StatefulContext.get(pid, "key", "default")
  """
  @spec get(GenServer.server(), key(), term()) :: term()
  def get(server, key, default) do
    case get(server, key) do
      {:ok, value} -> value
      {:error, :not_found} -> default
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

  ## Example

      :ok = StatefulContext.update(pid, "counter", 0, fn count -> count + 1 end)
  """
  @spec update(GenServer.server(), key(), term(), (term() -> term())) :: :ok
  def update(server, key, initial, fun) do
    GenServer.call(server, {:update, key, initial, fun})
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
  Returns the ETS table reference for direct access.

  Advanced users can use this for custom ETS operations.

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
    notify_on_change = Keyword.get(opts, :notify_on_change, true)

    # Create ETS table for data storage
    table =
      :ets.new(:stateful_context, [
        :set,
        :public,
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
  def handle_call({:update, key, initial, fun}, _from, state) do
    normalized_key = normalize_key(key)

    # Get current value or use initial
    current_value =
      case :ets.lookup(state.table, normalized_key) do
        [{^normalized_key, val}] -> val
        [] -> initial
      end

    # Apply update function
    new_value = fun.(current_value)

    # Write to ETS
    :ets.insert(state.table, {normalized_key, new_value})

    # Notify subscribers if enabled
    if state.notify_on_change do
      notify_subscribers(state.subscribers, normalized_key, {:ok, current_value}, new_value)
    end

    updated_state = %{state | updated_at: :os.system_time(:second)}
    {:reply, :ok, updated_state}
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

  defp normalize_key({namespace, key}) when is_binary(namespace) and is_binary(key) do
    "#{namespace}:#{key}"
  end

  defp normalize_key(key) when is_binary(key), do: key

  defp notify_subscribers(subscribers, key, old_value, new_value) do
    Enum.each(subscribers, fn subscriber ->
      send(subscriber, {:context_changed, key, old_value, new_value})
    end)
  end
end
