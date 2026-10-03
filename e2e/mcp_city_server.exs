# e2e/mcp_city_server.exs — a minimal MCP server over stdio for scenario 12.
# Newline-delimited JSON-RPC 2.0 on stdin/stdout; logs go to stderr only. Exits on stdin EOF,
# so it never outlives the scenario that spawned it.
defmodule E2E.CityServer do
  @cities %{"zubrowka" => 4_321_987, "elbonia city" => 77_010}

  def loop do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, reason} -> IO.puts(:stderr, "city server: stdin error #{inspect(reason)}")
      line -> handle(String.trim(line)); loop()
    end
  end

  defp handle(""), do: :ok

  defp handle(line) do
    case :json.decode(line) do
      %{"id" => id, "method" => method} = req -> reply(id, respond(method, Map.get(req, "params", %{})))
      _notification -> :ok
    end
  end

  defp respond("initialize", params) do
    {:ok,
     %{
       "protocolVersion" => Map.fetch!(params, "protocolVersion"),
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "e2e-city", "version" => "0.1.0"}
     }}
  end

  defp respond("tools/list", _params) do
    {:ok,
     %{
       "tools" => [
         %{
           "name" => "lookup_city",
           "description" => "Look up the population of a city in the e2e gazetteer.",
           "inputSchema" => %{
             "type" => "object",
             "properties" => %{"name" => %{"type" => "string", "description" => "city name"}},
             "required" => ["name"]
           }
         }
       ]
     }}
  end

  defp respond("tools/call", %{"name" => "lookup_city", "arguments" => %{"name" => name}}) do
    IO.puts(:stderr, "city server: lookup_city #{name}")

    case Map.fetch(@cities, String.downcase(name)) do
      {:ok, pop} -> {:ok, %{"content" => [%{"type" => "text", "text" => "#{name}: population #{pop}"}], "isError" => false}}
      :error -> {:ok, %{"content" => [%{"type" => "text", "text" => "unknown city: #{name}"}], "isError" => true}}
    end
  end

  defp respond("ping", _params), do: {:ok, %{}}
  defp respond(method, _params), do: {:error, %{"code" => -32601, "message" => "Method not found: #{method}"}}

  defp reply(id, {:ok, result}), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  defp reply(id, {:error, error}), do: write(%{"jsonrpc" => "2.0", "id" => id, "error" => error})

  defp write(map), do: IO.write(:stdio, [:json.encode(map), "\n"])
end

E2E.CityServer.loop()
