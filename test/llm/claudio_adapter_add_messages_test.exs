defmodule Normandy.LLM.ClaudioAdapterAddMessagesTest do
  @moduledoc """
  Task 7.5b: the adapter appends a conversation with one
  `Claudio.Messages.Request.add_messages/2` call (linear time), never a loop of
  `add_message/3`.
  """
  # Call tracing sets a global trace pattern on Claudio.Messages.Request.
  use ExUnit.Case, async: false

  alias Claudio.Messages.Request
  alias Normandy.Components.Message

  # Inside a `defimpl`, a public `def` is reachable at this qualified name.
  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  setup do
    {:module, Request} = Code.ensure_loaded(Request)
    _ = :erlang.trace_pattern({Request, :add_messages, 2}, true, [:local])
    _ = :erlang.trace_pattern({Request, :add_message, 3}, true, [:local])
    on_exit(fn -> :erlang.trace_pattern({Request, :_, :_}, false, [:local]) end)
    :ok
  end

  test "a 2_000-message history is one add_messages/2 call and no add_message/3" do
    history =
      for n <- 1..2_000 do
        %Message{role: if(rem(n, 2) == 1, do: "user", else: "assistant"), content: "m#{n}"}
      end

    # A process cannot trace its own calls (OTP 28 delivers nothing), so the build runs in
    # a child traced by this test process.
    test_pid = self()

    builder =
      spawn(fn ->
        receive do
          :go ->
            request =
              @impl_module.add_messages(
                Request.new("m"),
                [%Message{role: "system", content: "sys"} | history],
                false
              )

            send(test_pid, {:built, request})
        end
      end)

    1 = :erlang.trace(builder, true, [:call])
    send(builder, :go)
    assert_receive {:built, request}, 5_000
    # Every trace message from the builder is in the mailbox once this arrives.
    delivered = :erlang.trace_delivered(builder)
    assert_receive {:trace_delivered, ^builder, ^delivered}, 5_000

    assert length(request.messages) == 2_000
    assert request.system == "sys"
    assert_received {:trace, _, :call, {Request, :add_messages, [_request, entries]}}
    assert length(entries) == 2_000
    assert hd(entries) == {:user, "m1"}
    refute_received {:trace, _, :call, {Request, :add_message, _}}
  end
end
