defmodule Normandy.Batch.ProcessorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias Normandy.TurnError

  # Mock client for testing
  defmodule MockClient do
    use Normandy.Schema

    schema do
      field(:delay, :integer, default: 0)
      field(:failure_rate, :float, default: 0.0)
    end

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        # Simulate processing delay
        if client.delay > 0, do: Process.sleep(client.delay)

        # Simulate random failures based on failure_rate
        if :rand.uniform() < client.failure_rate do
          raise "Simulated failure"
        end

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "Response"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  # Fails when the input mentions "boom" (raises), "quit" (exits) or "toss" (throws) and
  # sleeps when it mentions "slow", so a test decides exactly which items fail or time out.
  defmodule PickyClient do
    use Normandy.Schema

    schema do
      field(:sleep_ms, :integer, default: 500)
    end

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        text = inspect(List.last(request.messages).content)
        if text =~ "slow", do: Process.sleep(client.sleep_ms)
        if text =~ "boom", do: raise("boom")
        if text =~ "quit", do: exit(:quit)
        if text =~ "toss", do: throw(:tossed)
        {:ok, %Normandy.LLM.Response{content: %{request.response_model | chat_message: "ok"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defmodule FailingClient do
    use Normandy.Schema

    schema do
    end

    defimpl Normandy.Agents.Model do
      def converse(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :invalid_request, retryable?: false)}

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp picky_agent do
    BaseAgent.init(%{client: %PickyClient{}, model: "test-model"})
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

      assert [{:ok, %{chat_message: "Response"}}, {:ok, _}, {:ok, _}] = results
    end

    test "preserves order with ordered: true", %{agent: agent} do
      inputs =
        Enum.map(1..10, fn i ->
          %{chat_message: "Message #{i}"}
        end)

      {:ok, results} = Processor.process_batch(agent, inputs, ordered: true)

      assert length(results) == 10
      assert Enum.all?(results, &match?({:ok, %{chat_message: "Response"}}, &1))
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
      assert stats.errors == []
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

      # Each item that runs past the timeout fails on its own.
      assert {:ok,
              [
                {:error, %TurnError{type: :task_down, reason: :timeout}},
                {:error, %TurnError{type: :task_down, reason: :timeout}}
              ]} =
               Processor.process_batch(agent, inputs, timeout: 100)
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
      assert stats.errors == []
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

    test "on_progress counts across chunks against the whole batch", %{agent: agent} do
      inputs = Enum.map(1..5, fn i -> %{chat_message: "Message #{i}"} end)
      test_pid = self()

      Processor.process_batch_chunked(agent, inputs,
        chunk_size: 2,
        on_progress: fn completed, total -> send(test_pid, {:progress, completed, total}) end
      )

      progress =
        for _ <- 1..5 do
          assert_receive {:progress, completed, total}
          {completed, total}
        end

      assert progress == [{1, 5}, {2, 5}, {3, 5}, {4, 5}, {5, 5}]
      refute_received {:progress, _, _}
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

  describe "results that say which items failed" do
    test "ordered results are {:ok, r} or {:error, e}, in input order" do
      inputs = [%{chat_message: "a"}, %{chat_message: "boom"}, %{chat_message: "c"}]

      assert {:ok, [{:ok, %{chat_message: "ok"}}, {:error, %RuntimeError{}}, {:ok, _}]} =
               Processor.process_batch(picky_agent(), inputs)
    end

    test "a raise, an exit and a throw are bare exceptions or :task_down TurnErrors, never a stacktrace" do
      inputs = [
        %{chat_message: "boom"},
        %{chat_message: "quit"},
        %{chat_message: "toss"}
      ]

      assert {:ok,
              [
                {:error, %RuntimeError{message: "boom"}},
                {:error, %TurnError{type: :task_down, reason: :quit}},
                {:error, %TurnError{type: :task_down, reason: {:nocatch, :tossed}}}
              ]} = Processor.process_batch(picky_agent(), inputs)
    end

    test "a Normandy error is returned bare" do
      agent = BaseAgent.init(%{client: %FailingClient{}, model: "test-model"})

      assert {:ok, [{:error, %Normandy.LLMError{}}]} =
               Processor.process_batch(agent, [%{chat_message: "a"}])
    end

    test "stats errors pair each error with its input" do
      boom = %{chat_message: "boom"}

      assert {:ok, %{errors: [{^boom, %RuntimeError{}}], success_count: 1}} =
               Processor.process_batch_with_stats(picky_agent(), [%{chat_message: "a"}, boom])
    end

    test "on_progress receives the number of completed items" do
      parent = self()
      # The first item finishes last, so an index-based report would end with 1.
      inputs = [%{chat_message: "slow"} | Enum.map(2..5, &%{chat_message: "m#{&1}"})]

      {:ok, _} =
        Processor.process_batch(picky_agent(), inputs,
          on_progress: fn completed, total -> send(parent, {:progress, completed, total}) end
        )

      reports =
        for _ <- 1..5 do
          assert_received {:progress, _, _} = report
          report
        end

      assert reports == Enum.map(1..5, &{:progress, &1, 5})
    end

    test "an item that exceeds :timeout fails on its own; the others still finish" do
      inputs = [%{chat_message: "a"}, %{chat_message: "slow"}]

      assert {:ok, [{:ok, _}, {:error, %TurnError{type: :task_down, reason: :timeout}}]} =
               Processor.process_batch(picky_agent(), inputs, timeout: 100)
    end

    test "on_error is called for a timed-out item" do
      parent = self()
      slow = %{chat_message: "slow"}

      {:ok, _} =
        Processor.process_batch(picky_agent(), [slow],
          timeout: 100,
          on_error: fn input, error -> send(parent, {:on_error, input, error}) end
        )

      assert_received {:on_error, ^slow, %TurnError{type: :task_down, reason: :timeout}}
    end
  end

  describe "process_batch_chunked/3 results" do
    test "ordered chunked results keep failures in place" do
      inputs = [%{chat_message: "a"}, %{chat_message: "boom"}, %{chat_message: "c"}]

      assert {:ok, [{:ok, _}, {:error, _}, {:ok, _}]} =
               Processor.process_batch_chunked(picky_agent(), inputs, chunk_size: 2)
    end

    test "unordered chunked results are stats that include the errors" do
      inputs = [%{chat_message: "a"}, %{chat_message: "boom"}, %{chat_message: "c"}]

      assert {:ok,
              %{
                total: 3,
                success_count: 2,
                error_count: 1,
                errors: [{%{chat_message: "boom"}, _}]
              }} =
               Processor.process_batch_chunked(picky_agent(), inputs,
                 chunk_size: 2,
                 ordered: false
               )
    end

    test "there is no delay after the last chunk" do
      inputs = Enum.map(1..4, &%{chat_message: "m#{&1}"})
      start = System.monotonic_time(:millisecond)

      {:ok, _} =
        Processor.process_batch_chunked(picky_agent(), inputs, chunk_size: 2, chunk_delay: 300)

      # Two chunks: one delay (300 ms), not two (600 ms).
      assert System.monotonic_time(:millisecond) - start < 550
    end
  end
end
