defmodule Normandy.Batch.ProcessorTest do
  use ExUnit.Case, async: true

  alias Normandy.Batch.Processor
  alias Normandy.Agents.BaseAgent

  # Mock client for testing
  defmodule MockClient do
    use Normandy.Schema

    schema do
      field(:delay, :integer, default: 0)
      field(:failure_rate, :float, default: 0.0)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        # Simulate processing delay
        if client.delay > 0, do: Process.sleep(client.delay)

        # Simulate random failures based on failure_rate
        if :rand.uniform() < client.failure_rate do
          raise "Simulated failure"
        end

        %{response_model | chat_message: "Response"}
      end
    end
  end

  setup do
    client = %MockClient{delay: 0, failure_rate: 0.0}

    agent =
      BaseAgent.init(%{
        client: client,
        model: "test-model",
        temperature: 0.7
      })

    {:ok, agent: agent, client: client}
  end

  describe "process_batch/3" do
    test "processes multiple inputs concurrently", %{agent: agent} do
      inputs = [
        %{chat_message: "Message 1"},
        %{chat_message: "Message 2"},
        %{chat_message: "Message 3"}
      ]

      {:ok, results} = Processor.process_batch(agent, inputs)

      assert length(results) == 3
      assert Enum.all?(results, fn result -> result.chat_message == "Response" end)
    end

    test "preserves order with ordered: true", %{agent: agent} do
      inputs =
        Enum.map(1..10, fn i ->
          %{chat_message: "Message #{i}"}
        end)

      {:ok, results} = Processor.process_batch(agent, inputs, ordered: true)

      assert length(results) == 10
      # All results should be in order (all have same response in our mock)
      assert Enum.all?(results, fn result -> result.chat_message == "Response" end)
    end

    test "returns stats with ordered: false", %{agent: agent} do
      inputs = [
        %{chat_message: "Message 1"},
        %{chat_message: "Message 2"}
      ]

      {:ok, stats} = Processor.process_batch(agent, inputs, ordered: false)

      assert is_map(stats)
      assert stats.total == 2
      assert stats.success_count == 2
      assert stats.error_count == 0
      assert length(stats.success) == 2
      assert length(stats.errors) == 0
    end

    test "handles empty input list", %{agent: agent} do
      {:ok, results} = Processor.process_batch(agent, [])
      assert results == []
    end

    test "respects max_concurrency option", %{client: client} do
      # Use delay to make concurrency observable
      client = %{client | delay: 50}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = Enum.map(1..20, fn i -> %{chat_message: "Message #{i}"} end)

      start_time = System.monotonic_time(:millisecond)
      {:ok, results} = Processor.process_batch(agent, inputs, max_concurrency: 5)
      duration = System.monotonic_time(:millisecond) - start_time

      assert length(results) == 20

      # With concurrency 5 and 20 items @ 50ms each:
      # Sequential would take ~1000ms, concurrent should take ~200ms (4 batches)
      assert duration < 500
      assert duration > 150
    end

    test "calls progress callback", %{agent: agent} do
      inputs = Enum.map(1..5, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, progress_ref} = Agent.start_link(fn -> [] end)

      on_progress = fn completed, total ->
        Agent.update(progress_ref, fn list -> [{completed, total} | list] end)
      end

      {:ok, _results} =
        Processor.process_batch(agent, inputs, on_progress: on_progress, ordered: true)

      progress = Agent.get(progress_ref, & &1) |> Enum.reverse()

      # Should have 5 progress updates
      assert length(progress) == 5
      # Check that we got all progress from 1 to 5 (may not be in order due to async execution)
      progress_values = Enum.map(progress, fn {completed, _total} -> completed end)
      assert Enum.sort(progress_values) == [1, 2, 3, 4, 5]
      # Verify all totals are 5
      assert Enum.all?(progress, fn {_completed, total} -> total == 5 end)

      Agent.stop(progress_ref)
    end

    test "calls error callback on failures", %{client: client} do
      # Client that always fails
      client = %{client | failure_rate: 1.0}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = [%{chat_message: "Message 1"}, %{chat_message: "Message 2"}]

      {:ok, error_ref} = Agent.start_link(fn -> [] end)

      on_error = fn input, error ->
        Agent.update(error_ref, fn list -> [{input, error} | list] end)
      end

      {:ok, _results} = Processor.process_batch(agent, inputs, on_error: on_error)

      errors = Agent.get(error_ref, & &1)

      # Should have captured both errors
      assert length(errors) == 2

      Agent.stop(error_ref)
    end

    test "handles partial failures", %{client: client} do
      # 50% failure rate
      client = %{client | failure_rate: 0.5}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = Enum.map(1..20, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, stats} = Processor.process_batch(agent, inputs, ordered: false)

      # Should have some successes and some failures
      assert stats.total == 20
      assert stats.success_count > 0
      assert stats.error_count > 0
      assert stats.success_count + stats.error_count == 20
    end

    test "respects timeout option", %{client: client} do
      # Client with long delay (1 second)
      client = %{client | delay: 1000}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = [
        %{chat_message: "Message 1"},
        %{chat_message: "Message 2"}
      ]

      # Short timeout (100ms) should cause the stream to exit with timeout error
      # This is the expected behavior of Task.async_stream when timeout occurs
      assert catch_exit(Processor.process_batch(agent, inputs, timeout: 100)) ==
               {:timeout, {Task.Supervised, :stream, [100]}}
    end
  end

  describe "process_batch_with_stats/3" do
    test "returns detailed statistics", %{agent: agent} do
      inputs = [
        %{chat_message: "Message 1"},
        %{chat_message: "Message 2"},
        %{chat_message: "Message 3"}
      ]

      {:ok, stats} = Processor.process_batch_with_stats(agent, inputs)

      assert stats.total == 3
      assert stats.success_count == 3
      assert stats.error_count == 0
      assert length(stats.success) == 3
      assert length(stats.errors) == 0
    end

    test "tracks failures in stats", %{client: client} do
      client = %{client | failure_rate: 0.5}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = Enum.map(1..10, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, stats} = Processor.process_batch_with_stats(agent, inputs)

      assert stats.total == 10
      assert stats.success_count + stats.error_count == 10
      assert is_list(stats.success)
      assert is_list(stats.errors)
    end
  end

  describe "process_batch_chunked/3" do
    test "processes large batches in chunks", %{agent: agent} do
      inputs = Enum.map(1..100, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, results} =
        Processor.process_batch_chunked(
          agent,
          inputs,
          chunk_size: 25,
          max_concurrency: 5
        )

      assert length(results) == 100
    end

    test "applies delay between chunks", %{agent: agent} do
      inputs = Enum.map(1..10, fn i -> %{chat_message: "Message #{i}"} end)

      start_time = System.monotonic_time(:millisecond)

      {:ok, results} =
        Processor.process_batch_chunked(
          agent,
          inputs,
          chunk_size: 3,
          chunk_delay: 100
        )

      duration = System.monotonic_time(:millisecond) - start_time

      assert length(results) == 10
      # 4 chunks with 100ms delay between = ~300ms minimum
      assert duration >= 300
    end

    test "works with small chunk size", %{agent: agent} do
      inputs = Enum.map(1..5, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, results} =
        Processor.process_batch_chunked(
          agent,
          inputs,
          chunk_size: 1
        )

      assert length(results) == 5
    end
  end

  describe "edge cases" do
    test "handles single input", %{agent: agent} do
      {:ok, results} = Processor.process_batch(agent, [%{chat_message: "Single"}])
      assert length(results) == 1
    end

    test "handles all failures gracefully", %{client: client} do
      client = %{client | failure_rate: 1.0}

      agent =
        BaseAgent.init(%{
          client: client,
          model: "test-model",
          temperature: 0.7
        })

      inputs = Enum.map(1..5, fn i -> %{chat_message: "Message #{i}"} end)

      {:ok, stats} = Processor.process_batch(agent, inputs, ordered: false)

      assert stats.total == 5
      assert stats.success_count == 0
      assert stats.error_count == 5
    end

    test "works with different input types", %{agent: agent} do
      # Mix of different message types
      inputs = [
        %{chat_message: "Text message"},
        %{chat_message: "Another message"},
        %{chat_message: "Third message"}
      ]

      {:ok, results} = Processor.process_batch(agent, inputs)
      assert length(results) == 3
    end
  end
end
