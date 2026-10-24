defmodule Normandy.Test.ContractsTest.DefaultsOnly do
  @moduledoc """
  Review Focus 3: a third-party store author passes only `impl:` (so `new:` defaults to
  `{impl, :new, []}` and `stored_entry_ids:` to nil). Every contract test runs; the delete
  tests check through the public API only.
  """
  use ExUnit.Case, async: true
  use Normandy.Test.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
end

defmodule Normandy.Test.ContractsTest.ExplicitNew do
  use ExUnit.Case, async: true

  use Normandy.Test.MemoryStoreContract,
    impl: Normandy.Behaviours.MemoryStore.InMemory,
    new: {Normandy.Behaviours.MemoryStore.InMemory, :new, [[]]}
end

defmodule Normandy.Test.ContractsTest do
  use ExUnit.Case, async: true

  alias Normandy.Test.ContractsTest.{DefaultsOnly, ExplicitNew}

  test "a contract used with impl: alone defines every contract test" do
    names = Enum.map(DefaultsOnly.__ex_unit__().tests, & &1.name)

    # Pinned to today's count so a dropped test is noticed; adding a contract test means updating it.
    assert length(names) == 19
    assert :"test deleting a fork keeps its parent's history" in names
  end

  test "a contract used with new: defines every contract test" do
    # Pinned to today's count so a dropped test is noticed; adding a contract test means updating it.
    assert length(ExplicitNew.__ex_unit__().tests) == 33
  end

  # The use line runs when the test module compiles: a bad option fails that compile.
  defp compile_use(contract, opts) do
    Code.compile_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, "Bad#{System.unique_integer([:positive])}")) do
          use ExUnit.Case, register: false
          use unquote(contract), unquote(Macro.escape(opts))
        end
      end
    )
  end

  for {contract, supported} <- [
        {Normandy.Test.SessionStoreContract, ":impl, :new, :stored_entry_ids"},
        {Normandy.Test.MemoryStoreContract, ":impl, :new"},
        {Normandy.Test.SessionRegistryContract, ":impl, :new"}
      ] do
    @contract contract
    @supported supported

    test "#{inspect(contract)} names a missing :impl" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: required :impl option not found, " <>
                     "received options: [:new]",
                   fn -> compile_use(@contract, new: {Kernel, :self, []}) end
    end

    test "#{inspect(contract)} names an unknown option and lists the supported ones" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: unknown option :store; " <>
                     "supported: #{@supported}",
                   fn ->
                     compile_use(@contract,
                       impl: Normandy.Behaviours.SessionStore.InMemory,
                       store: 1
                     )
                   end
    end

    test "#{inspect(contract)} wants :new as {module, function, args}" do
      assert_raise ArgumentError,
                   "#{inspect(@contract)}.__using__/1: invalid value for :new option: " <>
                     "expected tuple {mod, fun, args}, got: a tuple",
                   fn -> compile_use(@contract, impl: Kernel, new: {Kernel, :self}) end
    end
  end

  test "SessionStoreContract wants :stored_entry_ids as {module, function, args} or nil" do
    error =
      assert_raise ArgumentError, fn ->
        compile_use(Normandy.Test.SessionStoreContract,
          impl: Normandy.Behaviours.SessionStore.InMemory,
          stored_entry_ids: {Kernel, :ids}
        )
      end

    # NimbleOptions' {:or, ...} message lists one reason per allowed type.
    assert error.message =~
             "Normandy.Test.SessionStoreContract.__using__/1: expected :stored_entry_ids option " <>
               "to match at least one given type"

    assert error.message =~
             "invalid value for :stored_entry_ids option: expected tuple {mod, fun, args}, " <>
               "got: a tuple"
  end
end
