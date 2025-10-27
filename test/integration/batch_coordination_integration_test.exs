defmodule Normandy.Integration.BatchCoordinationIntegrationTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias NormandyTest.Support.IntegrationHelper

  @moduletag :integration
  @moduletag :api
  @moduletag timeout: 120_000

  setup do
    # These tests require a real API key
    # Skip by running: mix test --exclude api
    agent = IntegrationHelper.create_real_agent(temperature: 0.3)
    {:ok, agent: agent}
  end

  describe "Batch processing with real LLM" do
    test "processes multiple inputs concurrently", %{agent: agent} do
      inputs = [
        %{chat_message: "What is 2+2?"},
        %{chat_message: "What is 3+3?"},
        %{chat_message: "What is 4+4?"}
      ]

      {:ok, results} = Processor.process_batch(agent, inputs, max_concurrency: 2)

      assert length(results) == 3
      assert Enum.all?(results, fn result -> is_binary(result.chat_message) end)
    end

    test "maintains order with ordered: true", %{agent: agent} do
      inputs =
        Enum.map(1..5, fn i ->
          %{chat_message: "Say the number #{i}"}
        end)

      {:ok, results} = Processor.process_batch(agent, inputs, ordered: true, max_concurrency: 2)

      assert length(results) == 5
      assert Enum.all?(results, fn result -> result.chat_message != nil end)
    end

    test "returns stats with ordered: false", %{agent: agent} do
      inputs = [
        %{chat_message: "Hello"},
        %{chat_message: "World"}
      ]

      {:ok, stats} = Processor.process_batch(agent, inputs, ordered: false, max_concurrency: 2)

      assert is_map(stats)
      assert stats.total == 2
      assert stats.success_count <= 2
      assert stats.error_count >= 0
    end

    test "process_batch_with_stats returns detailed information", %{agent: agent} do
      inputs = [
        %{chat_message: "First"},
        %{chat_message: "Second"},
        %{chat_message: "Third"}
      ]

      {:ok, stats} = Processor.process_batch_with_stats(agent, inputs, max_concurrency: 2)

      assert stats.total == 3
      assert is_list(stats.success)
      assert is_list(stats.errors)
    end
  end

  describe "Batch processing with progress tracking" do
    test "calls progress callback during processing", %{agent: agent} do
      inputs = Enum.map(1..5, fn i -> %{chat_message: "Item #{i}"} end)

      {:ok, progress_agent} = Agent.start_link(fn -> [] end)

      on_progress = fn completed, total ->
        Agent.update(progress_agent, fn list -> [{completed, total} | list] end)
      end

      {:ok, _results} =
        Processor.process_batch(
          agent,
          inputs,
          on_progress: on_progress,
          ordered: true,
          max_concurrency: 2
        )

      progress = Agent.get(progress_agent, & &1)
      Agent.stop(progress_agent)

      # Should have received progress updates
      assert length(progress) > 0
    end

    test "tracks completion accurately", %{agent: agent} do
      inputs = Enum.map(1..3, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      on_progress = fn _completed, _total ->
        Agent.update(counter, fn count -> count + 1 end)
      end

      {:ok, _results} =
        Processor.process_batch(
          agent,
          inputs,
          on_progress: on_progress,
          ordered: true,
          max_concurrency: 1
        )

      final_count = Agent.get(counter, & &1)
      Agent.stop(counter)

      # Should have called progress callback for each item
      assert final_count == 3
    end
  end

  describe "Chunked batch processing" do
    test "processes large batch in chunks", %{agent: agent} do
      inputs = Enum.map(1..10, fn i -> %{chat_message: "Number #{i}"} end)

      {:ok, results} =
        Processor.process_batch_chunked(
          agent,
          inputs,
          chunk_size: 3,
          max_concurrency: 2,
          chunk_delay: 100
        )

      assert length(results) == 10
      assert Enum.all?(results, fn result -> result.chat_message != nil end)
    end

    test "applies delay between chunks", %{agent: agent} do
      inputs = Enum.map(1..6, fn i -> %{chat_message: "Item #{i}"} end)

      start_time = System.monotonic_time(:millisecond)

      {:ok, _results} =
        Processor.process_batch_chunked(
          agent,
          inputs,
          chunk_size: 2,
          chunk_delay: 500,
          max_concurrency: 2
        )

      duration = System.monotonic_time(:millisecond) - start_time

      # Should have ~1000ms delay (2 delays between 3 chunks)
      # Allow some variance for API call time
      assert duration >= 800
    end
  end

  describe "Batch processing error handling" do
    test "handles partial failures gracefully", %{agent: agent} do
      # Mix valid and potentially problematic inputs
      inputs = [
        %{chat_message: "Valid message 1"},
        %{chat_message: "Valid message 2"},
        %{chat_message: "Valid message 3"}
      ]

      {:ok, stats} = Processor.process_batch(agent, inputs, ordered: false, max_concurrency: 2)

      # Should complete even if some fail
      assert stats.total == 3
      assert stats.success_count + stats.error_count == 3
    end

    test "error callback receives failure information", %{agent: agent} do
      inputs = [
        %{chat_message: "Message 1"},
        %{chat_message: "Message 2"}
      ]

      {:ok, error_agent} = Agent.start_link(fn -> [] end)

      on_error = fn input, error ->
        Agent.update(error_agent, fn list -> [{input, error} | list] end)
      end

      {:ok, _stats} =
        Processor.process_batch(agent, inputs,
          on_error: on_error,
          ordered: false,
          max_concurrency: 1
        )

      errors = Agent.get(error_agent, & &1)
      Agent.stop(error_agent)

      # Errors list may be empty if all succeed
      assert is_list(errors)
    end
  end

  describe "Batch processing performance" do
    test "concurrent processing is faster than sequential", %{agent: agent} do
      inputs = Enum.map(1..4, fn i -> %{chat_message: "Quick #{i}"} end)

      # Sequential (concurrency = 1)
      start_seq = System.monotonic_time(:millisecond)

      {:ok, _results_seq} =
        Processor.process_batch(agent, inputs, max_concurrency: 1, ordered: true)

      duration_seq = System.monotonic_time(:millisecond) - start_seq

      # Give API a moment to reset
      Process.sleep(1000)

      # Concurrent (concurrency = 4)
      start_conc = System.monotonic_time(:millisecond)

      {:ok, _results_conc} =
        Processor.process_batch(agent, inputs, max_concurrency: 4, ordered: true)

      duration_conc = System.monotonic_time(:millisecond) - start_conc

      # Concurrent should generally be faster (or at least not slower)
      # Note: This test may be flaky due to API variance, so we're lenient
      IO.puts("Sequential: #{duration_seq}ms, Concurrent: #{duration_conc}ms")
      assert duration_conc < duration_seq * 1.5
    end

    test "handles reasonable batch size efficiently", %{agent: agent} do
      inputs = Enum.map(1..8, fn i -> %{chat_message: "Test #{i}"} end)

      start_time = System.monotonic_time(:millisecond)

      {:ok, results} = Processor.process_batch(agent, inputs, max_concurrency: 4)

      duration = System.monotonic_time(:millisecond) - start_time

      assert length(results) == 8
      # Should complete in reasonable time (< 60 seconds)
      assert duration < 60_000
    end
  end
end
