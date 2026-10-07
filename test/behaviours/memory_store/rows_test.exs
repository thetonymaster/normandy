defmodule Normandy.Behaviours.MemoryStore.RowsTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.Rows

  defmodule Recorder do
    @moduledoc false
    # Row access over an Agent holding `{rows, log}`; every put and delete is logged.
    @behaviour Normandy.Behaviours.MemoryStore.Rows

    @impl true
    def fetch(agent, key) do
      Agent.get(agent, fn {rows, _log} ->
        case Map.fetch(rows, key) do
          {:ok, v} -> {:ok, v}
          :error -> :error
        end
      end)
    end

    @impl true
    def put(agent, key, value) do
      Agent.update(agent, fn {rows, log} -> {Map.put(rows, key, value), [{:put, key} | log]} end)
    end

    @impl true
    def delete(agent, key) do
      Agent.update(agent, fn {rows, log} -> {Map.delete(rows, key), [{:delete, key} | log]} end)
    end

    @impl true
    def range(agent, {ns, prefix}) do
      Agent.get(agent, fn {rows, _log} ->
        for {{^ns, path}, doc} <- rows, is_binary(path), String.starts_with?(path, prefix) do
          {path, doc}
        end
        |> Enum.sort_by(&elem(&1, 0))
      end)
    end

    def log(agent), do: Agent.get(agent, fn {_rows, log} -> Enum.reverse(log) end)
    def clear_log(agent), do: Agent.update(agent, fn {rows, _log} -> {rows, []} end)
  end

  test "rename puts every destination row before it deletes any source row" do
    agent = start_supervised!({Agent, fn -> {%{}, []} end})
    access = {Recorder, agent}

    for path <- ["/memories/d/a", "/memories/d/b", "/memories/d/c"] do
      {:ok, 1} = Rows.put(access, "ns", path, "x", :new, [])
    end

    Recorder.clear_log(agent)

    assert {:ok, 3} = Rows.rename(access, "ns", "/memories/d", "/memories/e")

    ops = for {op, {"ns", path}} <- Recorder.log(agent), is_binary(path), do: op
    assert ops == [:put, :put, :put, :delete, :delete, :delete]

    assert Enum.map(Recorder.range(agent, {"ns", ""}), &elem(&1, 0)) ==
             ["/memories/e/a", "/memories/e/b", "/memories/e/c"]
  end
end
