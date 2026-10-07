defmodule Normandy.Test.SessionRegistryContract do
  @schema NimbleOptions.new!(
            impl: [
              type: :atom,
              required: true,
              doc: "The module implementing `Normandy.Behaviours.SessionRegistry`."
            ],
            new: [
              type: :mfa,
              doc:
                "`{module, function, args}` returning a fresh, empty handle, called once " <>
                  "per test. Default: `{impl, :new, []}`."
            ]
          )

  @moduledoc """
  The ExUnit tests every `Normandy.Behaviours.SessionRegistry` implementation must pass.
  Normandy runs them against `Native`, `Horde` and `Redis`; run them against yours.

      defmodule MyApp.SessionRegistryTest do
        use ExUnit.Case, async: true
        use Normandy.Test.SessionRegistryContract, impl: MyApp.SessionRegistry
      end

  Options, checked when the test module compiles (a bad one raises `ArgumentError`):

  #{Normandy.Options.docs(@schema)}

  Every test registers the fixed session id `"s1"`, so each handle must start empty
  (its own namespace, or `async: false` and a reset in a `setup` before the `use` line).
  A registry may be eventually consistent: every check after a change polls `whereis/2`
  every 10 ms for up to 3 s, and a process killed while registered must disappear within
  that time.
  """

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts),
    do: Normandy.Options.validate!(opts, @schema, {__MODULE__, :__using__, 1})

  @doc false
  # Polls `fun` until it returns true: at most `retries` more checks, 10 ms apart.
  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  def wait_until(fun, retries \\ 300) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, contract: __MODULE__] do
      contract_opts = contract.validate!(opts)
      @normandy_contract contract
      @reg Keyword.fetch!(contract_opts, :impl)
      @new_handle Keyword.get(contract_opts, :new) || {@reg, :new, []}

      setup do
        {mod, fun, args} = @new_handle
        {:ok, handle: apply(mod, fun, args)}
      end

      # NOTE: a registry may be eventually consistent (Horde reflects a register/
      # unregister through an async CRDT→ETS flush), so every "mutate then observe via
      # whereis" assertion polls. For a synchronous impl (Native) the poll returns on
      # the first check, so this costs nothing there.
      test "register then whereis returns the pid; unknown is :none", %{handle: h} do
        assert :none = @reg.whereis(h, "s1")
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == {:ok, self()} end)
      end

      test "double-register the same session is {:error, :taken}", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> match?({:ok, _}, @reg.whereis(h, "s1")) end)
        assert {:error, :taken} = @reg.register(h, "s1", self())
      end

      test "unregister frees the session", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert contract_wait_until(fn -> match?({:ok, _}, @reg.whereis(h, "s1")) end)
        assert :ok = @reg.unregister(h, "s1")
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == :none end)
        assert :ok = @reg.register(h, "s1", self())
      end

      test "a dead process auto-unregisters", %{handle: h} do
        parent = self()

        pid =
          spawn(fn ->
            :ok = @reg.register(h, "s1", self())
            send(parent, :registered)
            Process.sleep(:infinity)
          end)

        ref = Process.monitor(pid)
        assert_receive :registered, 1_000
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == {:ok, pid} end)

        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        # Registry cleanup is async on owner death; poll until it lands. Horde's
        # CRDT cleanup can exceed a few hundred ms under full-suite load, so the
        # budget is generous (the poll returns as soon as the condition holds, so
        # a fast impl like Native pays nothing).
        assert contract_wait_until(fn -> @reg.whereis(h, "s1") == :none end)
      end

      defp contract_wait_until(fun), do: @normandy_contract.wait_until(fun)
    end
  end
end
