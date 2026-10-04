defmodule Normandy.Tools.MemoryTelemetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Context, Memory}

  setup do
    test_pid = self()
    id = "mem-tel-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:normandy, :memory, :command, :stop],
        &__MODULE__.forward/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Handlers run in the emitting process; ignore events from other async tests.
  def forward(_event, measurements, meta, test_pid) do
    if self() == test_pid, do: send(test_pid, {:stop, measurements, meta})
  end

  defp call(tool, input) do
    ctx = %Context{tool_call_id: "c", values: %{memory_namespace: "acme/u-1"}}
    Memory.run(Memory.prepare_input(tool, input), ctx)
  end

  test "stop carries bytes, retries and status; no namespace or path by default" do
    t = Memory.new(store: {InMemory, InMemory.new()})
    call(t, %{"command" => "create", "path" => "/memories/a", "file_text" => "hello"})

    assert_receive {:stop, %{bytes_written: 5, bytes_read: 0, cas_retries: 0, duration: _},
                    %{command: "create", store: InMemory, status: :ok} = meta}

    refute Map.has_key?(meta, :namespace)
    refute Map.has_key?(meta, :path)
  end

  test "an error carries error_type; telemetry_include_paths adds namespace and path" do
    t = Memory.new(store: {InMemory, InMemory.new()}, telemetry_include_paths: true)
    call(t, %{"command" => "view", "path" => "/memories/missing"})

    assert_receive {:stop, _,
                    %{
                      status: :error,
                      error_type: :not_found,
                      namespace: "acme/u-1",
                      path: "/memories/missing"
                    }}
  end
end
