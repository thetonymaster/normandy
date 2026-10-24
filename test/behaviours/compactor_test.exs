defmodule Normandy.Behaviours.CompactorTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Compactor
  alias Normandy.Test.StubClient

  describe "NoOp default" do
    test "returns the acc unchanged and reports compacted: false" do
      acc = %{memory: :untouched, model: "claude-3-5-sonnet-20241022"}
      ctx = %{model: "claude-3-5-sonnet-20241022", window: 200_000}

      assert {^acc, meta} = Compactor.NoOp.maybe_compact(acc, ctx, [])
      assert meta.compacted == false
    end

    test "ignores ctx and opts entirely (never inspects the window)" do
      acc = :anything

      assert {:anything, %{compacted: false}} =
               Compactor.NoOp.maybe_compact(acc, %{model: nil, window: nil}, foo: :bar)
    end

    test "implements the Compactor behaviour" do
      behaviours = Compactor.NoOp.module_info(:attributes)[:behaviour] || []
      assert Normandy.Behaviours.Compactor in behaviours
    end
  end

  describe "WindowManager impl" do
    alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
    alias Normandy.Components.AgentMemory

    defp mem_with(messages) do
      Enum.reduce(messages, AgentMemory.new_memory(nil), fn {role, content}, m ->
        AgentMemory.add_message(m, role, content)
      end)
    end

    test "meta.dropped holds the removed entries, oldest first; kept entries keep their ids" do
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      before = AgentMemory.entry_chain(acc.memory)
      kept = AgentMemory.entry_chain(result.memory)

      assert meta.compacted
      assert meta.dropped == Enum.take(before, length(before) - length(kept))
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-length(kept)) |> Enum.map(& &1.id)
    end

    test "a kept message loses its thinking but keeps its id, and is not in meta.dropped" do
      thinking = [%{"type" => "thinking", "thinking" => "p", "signature" => "s"}]
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}

      memory =
        msgs
        |> mem_with()
        |> AgentMemory.add_message("assistant", %Normandy.Agents.ToolCallResponse{
          content: "answer",
          thinking: thinking
        })

      acc = %{memory: memory}
      last_id = memory.head

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      assert meta.compacted
      assert result.memory.head == last_id

      assert %Normandy.Agents.ToolCallResponse{content: "answer", thinking: []} =
               result.memory.entries[last_id].content

      refute Enum.any?(meta.dropped, &(&1.id == last_id))
    end

    test "nothing removed: meta.dropped is []" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}]), max_tokens: 1_000}
      {_result, meta} = WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])
      assert meta.dropped == []
    end

    test ":summarize reports the summarized entries as dropped, never the summary" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %Normandy.Test.MockSummarizerClient{summary_response: "a short summary"},
        model: "m"
      }

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      before = AgentMemory.entry_chain(acc.memory)
      [summary | kept] = AgentMemory.entry_chain(result.memory)

      refute summary.id in Enum.map(before, & &1.id)
      assert meta.dropped == Enum.take(before, length(before) - length(kept))
      assert Enum.map(kept, & &1.id) == before |> Enum.take(-length(kept)) |> Enum.map(& &1.id)
    end

    test ":summarize with no client raises naming :client" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}
      acc = %{memory: mem_with(msgs), model: "m"}

      assert_raise ArgumentError, ~r/:client/, fn ->
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )
      end
    end

    defp history_acc(max_tokens) do
      msgs =
        for i <- 1..40,
            do:
              {if(rem(i, 2) == 1, do: "user", else: "assistant"),
               String.duplicate("x", 600) <> "#{i}"}

      %{memory: mem_with(msgs), max_tokens: max_tokens}
    end

    test "reserves the agent's max_tokens for the answer by default" do
      {_acc, meta} = WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000}, [])

      # 20_000 window - 16_000 reserved = 4_000 tokens of history at most
      assert meta.compacted
      assert meta.tokens_after <= 4_000
    end

    test "an explicit :reserved_tokens wins" do
      {_acc, meta} =
        WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000}, reserved_tokens: 1_000)

      assert meta.tokens_after > 4_000
    end

    test "a reserve that leaves no room for history raises naming both numbers" do
      assert_raise ArgumentError, ~r/reserved_tokens \(16000\).*context window \(8000\)/, fn ->
        WMCompactor.maybe_compact(history_acc(16_000), %{window: 8_000}, [])
      end
    end

    test "a pinned :context_window wins over the window in ctx" do
      {_acc, meta} =
        WMCompactor.maybe_compact(history_acc(16_000), %{window: 8_000}, context_window: 20_000)

      # 20_000 pinned - 16_000 reserved = 4_000 tokens of history at most
      assert meta.compacted
      assert meta.tokens_after <= 4_000
    end

    test "the 1.x :max_tokens pin raises, naming :context_window" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: the :max_tokens option was renamed to " <>
                     ":context_window in 2.0 (the model's context window in tokens); see " <>
                     "MIGRATING-2.0.md §22",
                   fn ->
                     WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                       max_tokens: 20_000
                     )
                   end
    end

    test "a pinned :context_window that is not a positive integer raises, naming it" do
      for bad <- [nil, 0, "200000"] do
        assert_raise ArgumentError,
                     "Compactor.WindowManager: :context_window must be a positive integer " <>
                       "(the model's context window in tokens), got: #{inspect(bad)}",
                     fn ->
                       WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                         context_window: bad
                       )
                     end
      end
    end

    test "an acc without :max_tokens and no :reserved_tokens raises, not KeyError" do
      acc = %{memory: mem_with([{"user", "hi"}])}

      assert_raise ArgumentError,
                   "Compactor.WindowManager: the agent config has no :max_tokens to reserve " <>
                     "for the answer; pass :reserved_tokens in the compactor opts",
                   fn -> WMCompactor.maybe_compact(acc, %{window: 20_000}, []) end
    end

    test "an acc whose max_tokens is nil raises, naming it" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: the agent's max_tokens is the default " <>
                     ":reserved_tokens and must be a positive integer, got: nil; set it, or " <>
                     "pass :reserved_tokens in the compactor opts",
                   fn -> WMCompactor.maybe_compact(history_acc(nil), %{window: 20_000}, []) end
    end

    test "a :reserved_tokens that is not a non-negative integer raises, naming it" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: :reserved_tokens must be a non-negative " <>
                     "integer, got: nil",
                   fn ->
                     WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                       reserved_tokens: nil
                     )
                   end
    end

    test "no window in ctx and no explicit max_tokens → skips, reason :no_window" do
      acc = %{memory: mem_with([{"user", "hi"}])}

      assert {^acc, %{compacted: false, reason: :no_window}} =
               WMCompactor.maybe_compact(acc, %{model: "mystery", window: nil}, [])
    end

    test "conversation under the window is left untouched" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}]), max_tokens: 1_000}

      assert {result, meta} =
               WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])

      assert meta.compacted == false
      assert AgentMemory.history(result.memory) == AgentMemory.history(acc.memory)
    end

    test "the system prompt and tools the next call sends count against the window (AX-12)" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}
      before = Normandy.Context.WindowManager.estimate_conversation_tokens(acc.memory)
      window = before + 100

      ctx = %{model: "m", window: window}

      assert {_, %{compacted: false}} =
               WMCompactor.maybe_compact(acc, Map.put(ctx, :prompt_tokens, 50),
                 reserved_tokens: 16
               )

      assert {result, %{compacted: true} = meta} =
               WMCompactor.maybe_compact(acc, Map.put(ctx, :prompt_tokens, 150),
                 reserved_tokens: 16
               )

      assert meta.tokens_after <= window - 16 - 150
      assert length(AgentMemory.history(result.memory)) < length(msgs)
    end

    test "a prompt larger than the window leaves the newest message" do
      acc = %{memory: mem_with(for i <- 1..5, do: {"user", "message #{i}"})}

      assert {result, %{compacted: true}} =
               WMCompactor.maybe_compact(acc, %{model: "m", window: 100, prompt_tokens: 500},
                 reserved_tokens: 16
               )

      assert [_ | _] = AgentMemory.history(result.memory)
    end

    test "conversation over the window is truncated (oldest_first default)" do
      # ~25 chars each → ~6 tokens/msg + 10 overhead; 40 messages well exceeds a
      # tiny 80-token window minus 64 reserved.
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      assert meta.compacted == true
      assert meta.tokens_after < meta.tokens_before
      assert length(AgentMemory.history(result.memory)) < length(AgentMemory.history(acc.memory))
      assert meta.strategy == :oldest_first
    end

    test ":summarize strategy returns error meta when client returns unexpected response shape" do
      # The client returns a struct with no :chat_message key.
      # Summarizer.call_llm_for_summary/5 pattern-matches only %{chat_message: binary};
      # anything else falls to the `other ->` clause → {:error, {:unexpected_response, _}}.
      # That propagates through compress_conversation → ensure_within_limit as {:error, _},
      # hitting the error branch in Compactor.WindowManager.run/2:
      #   {:error, reason} -> {acc, %{compacted: false, error: reason}}
      client = %StubClient{reply: fn _ -> %Normandy.Agents.ToolCallResponse{} end}

      # 10 messages with enough content so estimate_conversation_tokens exceeds the
      # tiny window (window: 80, reserved_tokens: 64 → target = 16 tokens), forcing
      # truncate_with_summary to run. With target=16, div(16,2)=8, so keep_recent=max(0,5)=5,
      # and 10 > 5 ensures do_compress_conversation's summarize branch fires.
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}
      acc = %{memory: mem_with(msgs), client: client, model: "m"}

      original_history = AgentMemory.history(acc.memory)

      {returned_acc, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      # Error branch fired: compacted must be false and :error key must be present.
      assert meta.compacted == false

      assert Map.has_key?(meta, :error),
             "expected :error key in meta (error branch not reached), got: #{inspect(meta)}"

      # Reason must be the unexpected-response tuple, not swallowed or replaced.
      assert {:unexpected_response, %{}} = meta.error

      # The original acc is returned unchanged — no partially-mutated memory.
      assert AgentMemory.history(returned_acc.memory) == original_history
    end

    # Since Normandy.LLM.Call checks the response shape (6280534), a client answering
    # %Response{content: nil} is a wrong return: compaction raises Call's named
    # ArgumentError instead of returning {:error, {:unexpected_response, nil}}.
    test ":summarize raises Call's ArgumentError when the client answers content: nil" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %StubClient{reply: fn _ -> {:ok, %Normandy.LLM.Response{content: nil}} end},
        model: "m"
      }

      assert_raise ArgumentError,
                   ~r/must return \{:ok, %Normandy.LLM.Response\{\}\}.*content: nil/,
                   fn ->
                     WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
                       strategy: :summarize,
                       reserved_tokens: 64
                     )
                   end
    end

    test ":summarize keeps history when the summarization call fails" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %StubClient{
          reply: fn _ ->
            {:error, Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true)}
          end
        },
        model: "m"
      }

      original_history = AgentMemory.history(acc.memory)

      {returned_acc, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      assert meta.compacted == false
      assert %Normandy.LLMError{type: :overloaded} = meta.error
      assert AgentMemory.history(returned_acc.memory) == original_history
    end

    test ":summarize keeps history when the summary comes back empty" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %StubClient{reply: &%{&1 | chat_message: ""}},
        model: "m"
      }

      original_history = AgentMemory.history(acc.memory)

      {returned_acc, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          strategy: :summarize,
          reserved_tokens: 64
        )

      assert meta.compacted == false
      assert meta.error == :empty_summary
      assert AgentMemory.history(returned_acc.memory) == original_history
    end

    defp two_turns(old_msgs, new_msgs) do
      old =
        Enum.reduce(
          old_msgs,
          AgentMemory.initialize_turn(AgentMemory.new_memory(nil)),
          fn {r, c}, m -> AgentMemory.add_message(m, r, c) end
        )

      Enum.reduce(new_msgs, AgentMemory.initialize_turn(old), fn {r, c}, m ->
        AgentMemory.add_message(m, r, c)
      end)
    end

    defp estimate(history_msgs) do
      Enum.sum(
        for m <- history_msgs,
            do: Normandy.Context.WindowManager.estimate_message_content_tokens(m.content) + 10
      )
    end

    test "compacting only earlier turns' history reports tokens_removed: 0" do
      old = for i <- 1..6, do: {"user", "earlier turn message #{i} with padding text"}
      acc = %{memory: two_turns(old, [{"user", "q"}, {"assistant", "a"}])}

      {_acc2, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      assert meta.compacted
      assert meta.tokens_before > meta.tokens_after
      assert meta.tokens_removed == 0
    end

    test "removing this turn's messages reports their estimate (equals the net drop without a summary)" do
      msgs = for i <- 1..10, do: {"user", "this turn message #{i} with padding text"}
      acc = %{memory: two_turns([], msgs)}

      {acc2, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      kept = length(AgentMemory.history(acc2.memory))
      removed = Enum.take(AgentMemory.history(acc.memory), 10 - kept)

      assert meta.tokens_removed > 0
      assert meta.tokens_removed == estimate(removed)
      assert meta.tokens_removed == meta.tokens_before - meta.tokens_after
    end

    test ":summarize counts the removed messages, never the summary (gross > net)" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: two_turns([], msgs),
        client: %Normandy.Test.MockSummarizerClient{summary_response: "a short summary"},
        model: "m"
      }

      {acc2, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80},
          reserved_tokens: 64,
          strategy: :summarize
        )

      # summary + kept suffix
      kept = length(AgentMemory.history(acc2.memory)) - 1
      removed = Enum.take(AgentMemory.history(acc.memory), 10 - kept)

      assert meta.compacted
      assert meta.tokens_removed == estimate(removed)
      assert meta.tokens_removed > meta.tokens_before - meta.tokens_after
    end
  end
end
