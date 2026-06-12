defmodule Normandy.Components.AgentMemory.Entry do
  @moduledoc """
  One message in the conversation graph.

  Each entry is parent-linked: `parent_id` points to the prior entry on its
  branch (`nil` for a root). A linear conversation is a degenerate single-parent
  chain; branches are siblings sharing a `parent_id`.
  """

  defstruct [:id, :parent_id, :turn_id, :role, :content]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          turn_id: String.t(),
          role: String.t(),
          content: struct() | map() | list()
        }
end
