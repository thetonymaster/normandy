defmodule Normandy.Behaviours.SessionRegistry.Horde.ViaTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionRegistry.Horde.Via

  # The smallest :gen_statem: what matters is gen_statem's post-registration check
  # (gen:get_proc_name/1), which runs before init/1.
  defmodule Statem do
    @moduledoc false
    @behaviour :gen_statem
    @impl true
    def callback_mode, do: :handle_event_function
    @impl true
    def init(_), do: {:ok, :idle, nil}
    @impl true
    def handle_event(_type, _event, _state, _data), do: :keep_state_and_data
  end

  @starts 400

  # Under Horde.Registry as the via module, 16 concurrent starts failed nearly every
  # time with {:process_not_registered_via, Horde.Registry} (Horde 0.10.0).
  defp start_all(reg, via) do
    1..@starts
    |> Task.async_stream(
      fn i -> :gen_statem.start({:via, via, {reg, "s-#{i}"}}, Statem, [], []) end,
      max_concurrency: 16,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "concurrent :gen_statem starts under the via all register" do
    reg = HReg.new()
    results = start_all(reg, Via)

    assert Enum.frequencies_by(results, &elem(&1, 0)) == %{ok: @starts}

    for {:ok, pid} <- results, do: :ok = :gen_statem.stop(pid)
  end

  test "a started server is found under its via name and a second start is already_started" do
    reg = HReg.new()
    name = HReg.child_name(reg, "s-dup")
    assert {:via, Via, {^reg, "s-dup"}} = name

    {:ok, pid} = :gen_statem.start(name, Statem, [], [])
    assert Via.whereis_name({reg, "s-dup"}) == pid
    assert HReg.whereis(reg, "s-dup") == {:ok, pid}
    assert {:error, {:already_started, ^pid}} = :gen_statem.start(name, Statem, [], [])

    :ok = :gen_statem.stop(pid)
  end

  # 6.6a review: the via accepts only the 2-tuple child_name/2 builds, as its moduledoc
  # says; Horde's {registry, key, value} is refused by every callback.
  test "a 3-tuple name is refused by every callback" do
    reg = HReg.new()
    name = {reg, "s-3", :value}

    assert_raise FunctionClauseError, fn -> Via.register_name(name, self()) end
    assert_raise FunctionClauseError, fn -> Via.whereis_name(name) end
    assert_raise FunctionClauseError, fn -> Via.unregister_name(name) end
    assert_raise FunctionClauseError, fn -> Via.send(name, :msg) end
    assert HReg.whereis(reg, "s-3") == :none
  end
end
