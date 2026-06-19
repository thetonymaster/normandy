defmodule AgentHordeTest do
  use ExUnit.Case
  test "app module loads", do: assert(Code.ensure_loaded?(AgentHorde))
end
