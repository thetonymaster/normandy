defmodule Normandy.SessionRegistryContract do
  @moduledoc "Shared contract tests; `use` with `impl:` a SessionRegistry module."

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
      @reg impl

      setup do
        {:ok, handle: @reg.new()}
      end

      test "register then whereis returns the pid; unknown is :none", %{handle: h} do
        assert :none = @reg.whereis(h, "s1")
        assert :ok = @reg.register(h, "s1", self())
        assert {:ok, pid} = @reg.whereis(h, "s1")
        assert pid == self()
      end

      test "double-register the same session is {:error, :taken}", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert {:error, :taken} = @reg.register(h, "s1", self())
      end

      test "unregister frees the session", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert :ok = @reg.unregister(h, "s1")
        assert :none = @reg.whereis(h, "s1")
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
        assert {:ok, ^pid} = @reg.whereis(h, "s1")

        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        # Registry cleanup is async on owner death; poll briefly.
        assert wait_until(fn -> @reg.whereis(h, "s1") == :none end)
      end

      defp wait_until(fun, retries \\ 50) do
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
    end
  end
end
