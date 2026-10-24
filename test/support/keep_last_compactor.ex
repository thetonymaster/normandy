defmodule Normandy.Test.KeepLastCompactor do
  @moduledoc """
  Compactor for tests: keeps the last `opts[:keep]` messages of the active branch,
  re-added under their own entry ids and turns, and reports the rest in `meta.dropped`
  (the `Normandy.Behaviours.Compactor` contract). `compacted: true` only when it dropped
  something.
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Components.AgentMemory

  @impl true
  def maybe_compact(config, _ctx, opts) do
    entries = AgentMemory.entry_chain(config.memory)
    keep = Keyword.fetch!(opts, :keep)

    if length(entries) <= keep do
      {config, %{compacted: false, dropped: []}}
    else
      {dropped, kept} = Enum.split(entries, length(entries) - keep)

      fresh = %{
        AgentMemory.new_memory(config.memory.max_messages)
        | current_turn_id: config.memory.current_turn_id
      }

      memory =
        Enum.reduce(kept, fresh, fn entry, mem ->
          AgentMemory.add_message(mem, entry.role, entry.content,
            turn_id: entry.turn_id,
            id: entry.id
          )
        end)

      {%{config | memory: memory}, %{compacted: true, strategy: :keep_last, dropped: dropped}}
    end
  end
end
