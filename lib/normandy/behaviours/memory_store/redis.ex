if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.MemoryStore.Redis do
    @moduledoc """
    Durable `MemoryStore` over Redis. Each document is a hash; each namespace keeps a
    sorted set of its paths (score 0, so lexical order) for listing and prefixes. Every
    write is one Lua script, so compare-and-set, rename and delete_tree are atomic. All of
    a namespace's keys share the `{namespace}` hash tag, so they live in one Redis Cluster
    slot; the scripts derive document keys from the declared index key's prefix.
    A namespace's content bytes live in a counter key beside its index (the document
    count is the index's size), kept by the same scripts, so `put/6`'s limits are checked
    in the write's script.

    The handle is `{conn, prefix}`; the host owns the Redix connection.
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore
    alias Normandy.Options

    @new_opts_schema NimbleOptions.new!(
                       url: [
                         type: :string,
                         type_doc: "`t:String.t/0`",
                         required: true,
                         doc: "The Redis URL."
                       ],
                       prefix: [type: :string, required: true, doc: "The key prefix."]
                     )

    # KEYS: index, document, bytes. ARGV: path, content, expected, updated_at, max_bytes,
    # max_documents ('' = no limit). The limits rule is MemoryStore.check_limits/3's.
    @put """
    local cur = redis.call('HGET', KEYS[2], 'version')
    local exp = ARGV[3]
    if exp == 'new' and cur then return -1 end
    if exp ~= 'new' and exp ~= 'any' and cur ~= exp then return -1 end
    local was_bytes = tonumber(redis.call('GET', KEYS[3]) or '0')
    local was_docs = redis.call('ZCARD', KEYS[1])
    local bytes = was_bytes + string.len(ARGV[2])
    local docs = was_docs
    local v = 1
    if cur then
      v = tonumber(cur) + 1
      bytes = bytes - redis.call('HSTRLEN', KEYS[2], 'content')
    else
      docs = docs + 1
    end
    if ARGV[5] ~= '' and bytes > was_bytes and bytes > tonumber(ARGV[5]) then return {-2, bytes} end
    if ARGV[6] ~= '' and docs > was_docs and docs > tonumber(ARGV[6]) then return {-3, docs} end
    redis.call('HSET', KEYS[2], 'content', ARGV[2], 'version', v, 'updated_at', ARGV[4])
    redis.call('ZADD', KEYS[1], 0, ARGV[1])
    redis.call('SET', KEYS[3], bytes)
    return v
    """

    # KEYS: index, document, bytes.
    @delete """
    local cur = redis.call('HGET', KEYS[2], 'version')
    if not cur then return 0 end
    if ARGV[2] ~= 'any' and cur ~= ARGV[2] then return -1 end
    redis.call('DECRBY', KEYS[3], redis.call('HSTRLEN', KEYS[2], 'content'))
    redis.call('DEL', KEYS[2])
    redis.call('ZREM', KEYS[1], ARGV[1])
    if redis.call('ZCARD', KEYS[1]) == 0 then redis.call('DEL', KEYS[3]) end
    return 1
    """

    @list """
    local out = {}
    local function add(p)
      local k = ARGV[1] .. p
      table.insert(out, p)
      table.insert(out, redis.call('HSTRLEN', k, 'content'))
      table.insert(out, redis.call('HGET', k, 'updated_at'))
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then add(ARGV[2]) end
    local kids = redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255', 'LIMIT', 0, tonumber(ARGV[3]))
    for _, p in ipairs(kids) do add(p) end
    return out
    """

    # KEYS: index, bytes.
    @delete_tree """
    local n = 0
    local freed = 0
    local function del(p)
      local k = ARGV[1] .. p
      freed = freed + redis.call('HSTRLEN', k, 'content')
      redis.call('DEL', k)
      redis.call('ZREM', KEYS[1], p)
      n = n + 1
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then del(ARGV[2]) end
    for _, p in ipairs(redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255')) do del(p) end
    if n > 0 then redis.call('DECRBY', KEYS[2], freed) end
    if redis.call('ZCARD', KEYS[1]) == 0 then redis.call('DEL', KEYS[2]) end
    return n
    """

    @rename """
    local idx, dp, from, to = KEYS[1], ARGV[1], ARGV[2], ARGV[3]
    local moving
    if redis.call('ZSCORE', idx, from) then
      moving = {from}
    else
      moving = redis.call('ZRANGEBYLEX', idx, '[' .. from .. '/', '[' .. from .. '/\\255')
    end
    if #moving == 0 then return 0 end
    if redis.call('ZSCORE', idx, to) then return -1 end
    if #redis.call('ZRANGEBYLEX', idx, '[' .. to .. '/', '[' .. to .. '/\\255', 'LIMIT', 0, 1) > 0 then return -1 end
    for _, p in ipairs(moving) do
      local np = to .. string.sub(p, #from + 1)
      redis.call('RENAME', dp .. p, dp .. np)
      redis.call('ZREM', idx, p)
      redis.call('ZADD', idx, 0, np)
    end
    return #moving
    """

    # KEYS: index, bytes.
    @delete_namespace """
    for _, p in ipairs(redis.call('ZRANGE', KEYS[1], 0, -1)) do redis.call('DEL', ARGV[1] .. p) end
    redis.call('DEL', KEYS[1], KEYS[2])
    return 1
    """

    @scripts %{
      put: @put,
      delete: @delete,
      list: @list,
      delete_tree: @delete_tree,
      rename: @rename,
      delete_namespace: @delete_namespace
    }
    @shas Map.new(@scripts, fn {k, s} ->
            {k, :crypto.hash(:sha, s) |> Base.encode16(case: :lower)}
          end)

    @doc """
    Opens a Redix connection to `:url` and returns the store's handle `{conn, prefix}`.
    `:url` and `:prefix` are required.

    ## Options

    #{Options.docs(@new_opts_schema)}
    """
    @spec new(keyword()) :: {pid(), String.t()}
    def new(opts) do
      opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

      url = Keyword.fetch!(opts, :url)

      {:ok, conn} = Redix.start_link(url)
      {conn, Keyword.fetch!(opts, :prefix)}
    end

    @impl true
    def list({conn, _} = h, ns, prefix) do
      with {:ok, flat} <-
             eval(conn, :list, [idx(h, ns)], [doc_prefix(h, ns), prefix, MemoryStore.list_limit()]) do
        entries =
          flat
          |> Enum.chunk_every(3)
          |> Enum.map(fn [path, size, at] ->
            %{path: path, size: size, updated_at: from_micros(at)}
          end)
          |> Enum.take(MemoryStore.list_limit())

        {:ok, entries}
      end
    end

    @impl true
    def get({conn, _} = h, ns, path) do
      case Redix.command(conn, ["HMGET", doc(h, ns, path), "content", "version"]) do
        {:ok, [nil, _]} ->
          :not_found

        {:ok, [content, version]} ->
          {:ok, %{content: content, version: String.to_integer(version)}}

        {:error, _} = error ->
          error
      end
    end

    @impl true
    def put({conn, _} = h, ns, path, content, expected, limits \\ []) do
      limits = MemoryStore.validate_limits!(limits, __MODULE__)

      args = [
        path,
        content,
        expected_arg(expected),
        Integer.to_string(System.os_time(:microsecond)),
        limit_arg(Keyword.fetch!(limits, :max_bytes)),
        limit_arg(Keyword.fetch!(limits, :max_documents))
      ]

      case eval(conn, :put, [idx(h, ns), doc(h, ns, path), bytes_key(h, ns)], args) do
        {:ok, -1} -> {:error, :conflict}
        {:ok, [-2, bytes]} -> {:error, {:namespace_full, :bytes, bytes}}
        {:ok, [-3, documents]} -> {:error, {:namespace_full, :documents, documents}}
        {:ok, version} when is_integer(version) -> {:ok, version}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete({conn, _} = h, ns, path, expected) do
      keys = [idx(h, ns), doc(h, ns, path), bytes_key(h, ns)]

      case eval(conn, :delete, keys, [path, expected_arg(expected)]) do
        {:ok, 1} -> :ok
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_tree({conn, _} = h, ns, prefix),
      do: eval(conn, :delete_tree, [idx(h, ns), bytes_key(h, ns)], [doc_prefix(h, ns), prefix])

    @impl true
    def rename({conn, _} = h, ns, from, to) do
      case eval(conn, :rename, [idx(h, ns)], [doc_prefix(h, ns), from, to]) do
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :exists}
        {:ok, n} -> {:ok, n}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_namespace({conn, _} = h, ns) do
      with {:ok, 1} <-
             eval(conn, :delete_namespace, [idx(h, ns), bytes_key(h, ns)], [doc_prefix(h, ns)]),
           do: :ok
    end

    # EVALSHA first; on NOSCRIPT (a restarted or flushed server) send the source once.
    defp eval(conn, name, keys, args) do
      args = Enum.map(args, &to_string/1)
      base = [Integer.to_string(length(keys)) | keys ++ args]

      case Redix.command(conn, ["EVALSHA", Map.fetch!(@shas, name) | base]) do
        {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
          Redix.command(conn, ["EVAL", Map.fetch!(@scripts, name) | base])

        other ->
          other
      end
    end

    defp expected_arg(:new), do: "new"
    defp expected_arg(:any), do: "any"
    defp expected_arg(v) when is_integer(v), do: Integer.to_string(v)

    defp limit_arg(nil), do: ""
    defp limit_arg(limit), do: Integer.to_string(limit)

    defp idx({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:idx"
    defp doc_prefix({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:doc:"
    defp bytes_key({_, prefix}, ns), do: "#{prefix}:mem:{#{enc(ns)}}:bytes"

    # URL-safe base64 has no `}` or `:`, so a namespace can never alter the key structure
    # or produce an empty hash tag.
    defp enc(ns), do: Base.url_encode64(ns, padding: false)
    defp doc(h, ns, path), do: doc_prefix(h, ns) <> path

    defp from_micros(at), do: at |> String.to_integer() |> DateTime.from_unix!(:microsecond)
  end
end
