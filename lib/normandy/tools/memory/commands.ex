defmodule Normandy.Tools.Memory.Commands do
  @moduledoc false
  # Placeholder; Task 10 replaces this body. The first clause only keeps the inferred
  # return type wide enough for Memory.run/2 to compile without warnings.
  def run(_tool, ""), do: {:ok, "", %{}}

  def run(_tool, _namespace),
    do: {:error, :invalid_input, "Error: memory commands are not implemented"}
end
