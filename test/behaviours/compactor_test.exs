defmodule Normandy.Test.BadResponseClient do
  @moduledoc """
  Stub LLM client that returns a response with no :chat_message key, triggering
  {:error, {:unexpected_response, _}} in Summarizer.call_llm_for_summary/5.
  """
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, _response_model, _opts),
      do: %{}
  end
end

defmodule Normandy.Test.EmptySummaryClient do
  @moduledoc "Stub LLM client whose summary comes back empty."
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts),
      do: %{response_model | chat_message: ""}
  end
end

defmodule Normandy.Test.LLMErrorCompactionClient do
  @moduledoc "Stub LLM client whose summarization call fails."
  use Normandy.Schema

  schema do
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(_client, _model, _temperature, _max_tokens, _messages, _response_model, _opts),
      do: {:error, Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true)}
  end
end

defmodule Normandy.Behaviours.CompactorTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Compactor

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

    test "no window in ctx and no explicit max_tokens → skips, reason :no_window" do
      acc = %{memory: mem_with([{"user", "hi"}])}

      assert {^acc, %{compacted: false, reason: :no_window}} =
               WMCompactor.maybe_compact(acc, %{model: "mystery", window: nil}, [])
    end

    test "conversation under the window is left untouched" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}])}

      assert {result, meta} =
               WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])

      assert meta.compacted == false
      assert AgentMemory.history(result.memory) == AgentMemory.history(acc.memory)
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
      # Normandy.Test.BadResponseClient.converse/7 returns %{} (no :chat_message key).
      # Summarizer.call_llm_for_summary/5 pattern-matches only %{chat_message: binary};
      # anything else falls to the `other ->` clause → {:error, {:unexpected_response, _}}.
      # That propagates through compress_conversation → ensure_within_limit as {:error, _},
      # hitting the error branch in Compactor.WindowManager.run/2:
      #   {:error, reason} -> {acc, %{compacted: false, error: reason}}
      client = %Normandy.Test.BadResponseClient{}

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

    test ":summarize keeps history when the summarization call fails" do
      msgs = for i <- 1..10, do: {"user", "message number #{i} in this test conversation padding"}

      acc = %{
        memory: mem_with(msgs),
        client: %Normandy.Test.LLMErrorCompactionClient{},
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
      acc = %{memory: mem_with(msgs), client: %Normandy.Test.EmptySummaryClient{}, model: "m"}
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
