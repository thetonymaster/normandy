defmodule Normandy.Components.AgentMemory.Entry do
  @moduledoc """
  One message in the conversation graph.

  Each entry is parent-linked: `parent_id` points to the prior entry on its
  branch (`nil` for a root). A linear conversation is a degenerate single-parent
  chain; branches are siblings sharing a `parent_id`.

  `wire` and `tokens` are derived from `content` when `Normandy.Components.AgentMemory`
  sets it: `wire` is what the model is sent for it (a string or a list of content
  blocks) and `tokens` its estimate (`Normandy.Context.WindowManager`'s, plus 10 for the
  message). They are never persisted: a session store keeps `id`, `parent_id`,
  `turn_id`, `role` and `content`, and an entry it returns has both `nil` until
  `Normandy.Components.AgentMemory.from_entries/1` fills them. Build entries with
  `Normandy.Components.AgentMemory`, not by hand; a hand-built entry with `nil` fields is
  encoded each time it is read.
  """

  defstruct [:id, :parent_id, :turn_id, :role, :content, wire: nil, tokens: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          turn_id: String.t(),
          role: String.t(),
          content: struct() | map() | list(),
          wire: String.t() | list() | nil,
          tokens: non_neg_integer() | nil
        }
end
