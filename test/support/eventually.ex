defmodule Normandy.Test.Eventually do
  @moduledoc """
  Polling helper for eventually-consistent assertions. Some registries/stores
  (notably Horde) reflect a mutation through an async CRDT→ETS flush, so an
  immediate observation can race it. `wait_until/2` polls until the predicate holds
  (or the budget is exhausted). For a synchronous impl the predicate holds on the
  first check, so this costs nothing there.

      import Normandy.Test.Eventually
      assert wait_until(fn -> match?({:ok, _}, Registry.whereis(h, sid)) end)
  """

  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  def wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, retries - 1)
    end
  end
end
