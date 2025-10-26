defmodule Normandy.Coordination.SharedContext do
  @moduledoc """
  Manages shared context between multiple agents.

  SharedContext provides a key-value store that multiple agents can
  read from and write to, enabling information sharing across agent
  boundaries.

  ## Example

      # Create shared context
      context = SharedContext.new()

      # Store data
      context = SharedContext.put(context, "research_results", data)

      # Retrieve data
      {:ok, data} = SharedContext.get(context, "research_results")

      # Store with namespace
      context = SharedContext.put(context, {"agent_1", "status"}, "processing")
  """

  @type key :: String.t() | {String.t(), String.t()}
  @type t :: %__MODULE__{
          data: map(),
          metadata: map()
        }

  defstruct data: %{},
            metadata: %{created_at: nil, updated_at: nil}

  @doc """
  Creates a new shared context.

  ## Example

      context = SharedContext.new()
  """
  @spec new() :: t()
  def new do
    timestamp = :os.system_time(:second)

    %__MODULE__{
      data: %{},
      metadata: %{
        created_at: timestamp,
        updated_at: timestamp
      }
    }
  end

  @doc """
  Stores a value in the shared context.

  ## Examples

      # Simple key
      context = SharedContext.put(context, "key", "value")

      # Namespaced key
      context = SharedContext.put(context, {"agent_1", "status"}, "active")
  """
  @spec put(t(), key(), term()) :: t()
  def put(%__MODULE__{data: data, metadata: metadata} = context, key, value) do
    normalized_key = normalize_key(key)
    updated_data = Map.put(data, normalized_key, value)

    %{
      context
      | data: updated_data,
        metadata: Map.put(metadata, :updated_at, :os.system_time(:second))
    }
  end

  @doc """
  Retrieves a value from the shared context.

  Returns `{:ok, value}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      {:ok, value} = SharedContext.get(context, "key")
      {:error, :not_found} = SharedContext.get(context, "missing")
  """
  @spec get(t(), key()) :: {:ok, term()} | {:error, :not_found}
  def get(%__MODULE__{data: data}, key) do
    normalized_key = normalize_key(key)

    case Map.fetch(data, normalized_key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Retrieves a value with a default if not found.

  ## Example

      value = SharedContext.get(context, "key", "default")
  """
  @spec get(t(), key(), term()) :: term()
  def get(%__MODULE__{} = context, key, default) do
    case get(context, key) do
      {:ok, value} -> value
      {:error, :not_found} -> default
    end
  end

  @doc """
  Checks if a key exists in the context.

  ## Example

      SharedContext.has_key?(context, "key")
      #=> true
  """
  @spec has_key?(t(), key()) :: boolean()
  def has_key?(%__MODULE__{data: data}, key) do
    normalized_key = normalize_key(key)
    Map.has_key?(data, normalized_key)
  end

  @doc """
  Deletes a key from the context.

  ## Example

      context = SharedContext.delete(context, "key")
  """
  @spec delete(t(), key()) :: t()
  def delete(%__MODULE__{data: data, metadata: metadata} = context, key) do
    normalized_key = normalize_key(key)
    updated_data = Map.delete(data, normalized_key)

    %{
      context
      | data: updated_data,
        metadata: Map.put(metadata, :updated_at, :os.system_time(:second))
    }
  end

  @doc """
  Returns all keys in the context.

  ## Example

      keys = SharedContext.keys(context)
      #=> ["key1", "agent_1:status"]
  """
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{data: data}) do
    Map.keys(data)
  end

  @doc """
  Updates a value using a function.

  If the key doesn't exist, uses the initial value.

  ## Example

      context = SharedContext.update(context, "counter", 0, fn count -> count + 1 end)
  """
  @spec update(t(), key(), term(), (term() -> term())) :: t()
  def update(%__MODULE__{} = context, key, initial, fun) do
    current_value = get(context, key, initial)
    new_value = fun.(current_value)
    put(context, key, new_value)
  end

  @doc """
  Merges data from another context.

  ## Example

      context = SharedContext.merge(context1, context2)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{data: data1, metadata: metadata}, %__MODULE__{data: data2}) do
    %__MODULE__{
      data: Map.merge(data1, data2),
      metadata: Map.put(metadata, :updated_at, :os.system_time(:second))
    }
  end

  @doc """
  Returns all data in the context.

  ## Example

      data = SharedContext.to_map(context)
      #=> %{"key1" => "value1", "agent_1:status" => "active"}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{data: data}), do: data

  # Private functions

  defp normalize_key({namespace, key}) when is_binary(namespace) and is_binary(key) do
    "#{namespace}:#{key}"
  end

  defp normalize_key(key) when is_binary(key), do: key
end
