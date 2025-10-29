defmodule NormandyIntegration.DSLComprehensiveTest do
  @moduledoc """
  Comprehensive integration tests for all DSL features and pattern matching helpers.

  These tests demonstrate realistic usage scenarios combining:
  - Pattern matching helpers (Normandy.Coordination.Pattern)
  - Agent DSL (Normandy.DSL.Agent)
  - Workflow DSL (Normandy.DSL.Workflow)
  """
  use ExUnit.Case, async: false

  alias Normandy.Coordination.Pattern

  # Define agents for testing using the DSL
  defmodule ResearchAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.7)
      system_prompt("You are a research assistant. Provide concise, factual responses.")
    end
  end

  defmodule AnalyzerAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.5)
      system_prompt("You are an analytical agent. Analyze information critically.")
    end
  end

  defmodule SummarizerAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.3)
      system_prompt("You are a summarization agent. Create concise summaries.")
    end
  end

  defmodule SentimentAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.1)
      system_prompt("Analyze sentiment. Respond with: positive, negative, or neutral.")
    end
  end

  defmodule TopicAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.1)
      system_prompt("Identify the main topic in one word.")
    end
  end

  defmodule QualityAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.1)
      system_prompt("Rate content quality. Respond with a number 1-10.")
    end
  end

  defmodule FastAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.8)
      max_tokens(100)
      system_prompt("Provide very brief answers in 1-2 words.")
    end
  end

  defmodule ValidationAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.0)

      system_prompt("""
      Validate input text. Respond with exactly:
      - "VALID" if the text is reasonable
      - "INVALID" if the text is empty or nonsensical
      """)
    end
  end

  defmodule ProcessorAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.5)
      system_prompt("Process the validated input and provide a response.")
    end
  end

  defmodule StructuredAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      temperature(0.3)
      background("You are an assistant that provides structured information.")

      steps("""
      1. Understand the user's request
      2. Gather relevant information
      3. Structure the response clearly
      """)

      output_instructions("Provide responses in a clear, numbered list format.")
    end
  end

  # Define workflows for testing

  defmodule ResearchWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :gather do
        agent(ResearchAgent)
        # No input specified - will use initial_input from state.current_input
      end

      step :analyze do
        agent(AnalyzerAgent)
        input(from: :gather)
      end

      step :summarize do
        agent(SummarizerAgent)
        input(from: :analyze)
      end
    end
  end

  defmodule ParallelAnalysisWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      parallel :analyze do
        agent(SentimentAgent, name: :sentiment)
        agent(TopicAgent, name: :topic)
        agent(QualityAgent, name: :quality)
        # No input specified - will use initial_input from state.current_input
      end
    end
  end

  defmodule RaceWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      race :fastest do
        agent(FastAgent, name: :fast1)
        agent(FastAgent, name: :fast2)
        # No input specified - will use initial_input from state.current_input
      end
    end
  end

  defmodule ConditionalWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :validate do
        agent(ValidationAgent)
        # No input specified - will use initial_input from state.current_input
      end

      step :process do
        agent(ProcessorAgent)
        input(from: :validate)
      end
    end
  end

  setup do
    # Check if API key is available
    unless NormandyTest.Support.NormandyIntegrationHelper.api_key_available?() do
      {:skip, "API key not available. Set API_KEY or ANTHROPIC_API_KEY environment variable."}
    else
      # Create real client for agents
      client = NormandyTest.Support.NormandyIntegrationHelper.create_real_client()

      # Create all agent instances
      {:ok, research_agent} = ResearchAgent.new(client: client)
      {:ok, analyzer_agent} = AnalyzerAgent.new(client: client)
      {:ok, summarizer_agent} = SummarizerAgent.new(client: client)
      {:ok, sentiment_agent} = SentimentAgent.new(client: client)
      {:ok, topic_agent} = TopicAgent.new(client: client)
      {:ok, quality_agent} = QualityAgent.new(client: client)
      {:ok, fast_agent} = FastAgent.new(client: client)
      {:ok, validation_agent} = ValidationAgent.new(client: client)
      {:ok, processor_agent} = ProcessorAgent.new(client: client)
      {:ok, structured_agent} = StructuredAgent.new(client: client)

      agents_map = %{
        ResearchAgent => research_agent,
        AnalyzerAgent => analyzer_agent,
        SummarizerAgent => summarizer_agent,
        SentimentAgent => sentiment_agent,
        TopicAgent => topic_agent,
        QualityAgent => quality_agent,
        FastAgent => fast_agent,
        ValidationAgent => validation_agent,
        ProcessorAgent => processor_agent,
        StructuredAgent => structured_agent
      }

      {:ok, client: client, agents: agents_map}
    end
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 1: Multi-Step Research Workflow with Pattern Matching", %{agents: agents_map} do
    # Execute the workflow
    result =
      ResearchWorkflow.execute(
        agents: agents_map,
        initial_input: "What is Elixir?"
      )

    # Use pattern matching to validate success
    assert Pattern.ok?(result)

    # Unwrap the result safely
    results = Pattern.unwrap!(result)

    # Verify all steps completed
    assert Map.has_key?(results, :gather)
    assert Map.has_key?(results, :analyze)
    assert Map.has_key?(results, :summarize)

    # Verify results are valid maps
    assert is_map(results.gather)
    assert is_map(results.analyze)
    assert is_map(results.summarize)

    # Use pattern matching helpers to extract data
    step_results = [
      {:ok, results.gather},
      {:ok, results.analyze},
      {:ok, results.summarize}
    ]

    # Verify all steps succeeded using all_ok (returns {:ok, values} or {:error, errors})
    all_ok_result = Pattern.all_ok(step_results)
    assert Pattern.ok?(all_ok_result)

    # Collect all successful results (returns {:ok, list})
    all_data_result = Pattern.collect_ok(step_results)
    assert Pattern.ok?(all_data_result)
    all_data = Pattern.unwrap!(all_data_result)
    assert length(all_data) == 3
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 2: Parallel Analysis with Result Aggregation", %{agents: agents_map} do
    input_text = "Elixir is a fantastic functional programming language!"

    # Execute parallel analysis
    result =
      ParallelAnalysisWorkflow.execute(
        agents: agents_map,
        initial_input: input_text
      )

    # Verify workflow succeeded
    assert Pattern.ok?(result)
    results = Pattern.unwrap!(result)

    # Get parallel analysis results
    analysis = results.analyze

    # Verify we have results for each named agent
    assert Map.has_key?(analysis, :sentiment)
    assert Map.has_key?(analysis, :topic)
    assert Map.has_key?(analysis, :quality)

    # The parallel analysis results are wrapped in :ok tuples
    # Unwrap and verify each one
    assert Pattern.ok?(analysis.sentiment)
    assert Pattern.ok?(analysis.topic)
    assert Pattern.ok?(analysis.quality)

    # Unwrap to get the actual response maps
    sentiment_response = Pattern.unwrap!(analysis.sentiment)
    topic_response = Pattern.unwrap!(analysis.topic)
    quality_response = Pattern.unwrap!(analysis.quality)

    assert is_map(sentiment_response)
    assert is_map(topic_response)
    assert is_map(quality_response)

    # Demonstrate using Pattern helpers on the workflow result itself
    workflow_result =
      ParallelAnalysisWorkflow.execute(
        agents: agents_map,
        initial_input: input_text
      )

    # Verify workflow succeeded using pattern matching
    assert Pattern.ok?(workflow_result)
    unwrapped = Pattern.unwrap!(workflow_result)
    assert Map.has_key?(unwrapped, :analyze)
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 3: Race Condition with Pattern Matching", %{agents: agents_map} do
    # Execute race workflow
    result =
      RaceWorkflow.execute(
        agents: agents_map,
        initial_input: "Quick answer: what is 2+2?"
      )

    # Verify we got a result
    assert Pattern.ok?(result)

    # Unwrap and verify we got exactly one winner
    results = Pattern.unwrap!(result)
    assert Map.has_key?(results, :fastest)

    # The race returns a single result (the first to complete)
    fastest_result = results.fastest
    assert is_map(fastest_result)

    # Use Pattern.find_ok to find the first successful result from a list
    race_results = [{:ok, fastest_result}]
    first_success = Pattern.find_ok(race_results)

    assert Pattern.ok?(first_success)
    assert Pattern.unwrap!(first_success) == fastest_result
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 4: Conditional Workflow with Pattern Guards", %{agents: agents_map} do
    # Test with valid input
    result_valid =
      ConditionalWorkflow.execute(
        agents: agents_map,
        initial_input: "This is a valid input for processing"
      )

    assert Pattern.ok?(result_valid)
    results = Pattern.unwrap!(result_valid)

    # Use Pattern.then to chain operations
    validation_check =
      {:ok, results.validate}
      |> Pattern.then(fn validation ->
        assert is_map(validation)
        {:ok, :validated}
      end)

    assert Pattern.ok?(validation_check)

    # Verify processing happened after validation
    assert Map.has_key?(results, :process)
    assert is_map(results.process)

    # Test with potentially invalid input
    result_empty =
      ConditionalWorkflow.execute(
        agents: agents_map,
        initial_input: "Test"
      )

    # Even with short input, workflow should complete
    # (ValidationAgent will still respond, just might say INVALID)
    assert Pattern.ok?(result_empty)
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 5: Agent with Structured Output", %{client: client} do
    {:ok, agent} = StructuredAgent.new(client: client)

    # Run the agent
    {updated_agent, response} = StructuredAgent.run(agent, "List 3 benefits of Elixir")

    # Use pattern matching to verify response structure
    assert is_map(response)

    # Verify memory was updated
    assert length(updated_agent.memory.history) > 0

    # Run again to test memory accumulation
    {updated_agent2, response2} = StructuredAgent.run(updated_agent, "And what about OTP?")

    assert is_map(response2)
    assert length(updated_agent2.memory.history) > length(updated_agent.memory.history)

    # Test reset_memory
    reset_agent = StructuredAgent.reset_memory(updated_agent2)
    assert length(reset_agent.memory.history) == 0

    # Use pattern matching helpers to validate results
    results = [{:ok, response}, {:ok, response2}]
    all_ok_result = Pattern.all_ok(results)
    assert Pattern.ok?(all_ok_result)

    all_responses_result = Pattern.collect_ok(results)
    assert Pattern.ok?(all_responses_result)
    all_responses = Pattern.unwrap!(all_responses_result)
    assert length(all_responses) == 2
  end

  @tag :normandy_integration
  @tag timeout: 120_000
  test "Test 6: Error Recovery and Pattern Matching Utilities", %{agents: agents_map} do
    # Test with missing agent to trigger error
    incomplete_agents = Map.delete(agents_map, ProcessorAgent)

    result =
      ConditionalWorkflow.execute(
        agents: incomplete_agents,
        initial_input: "Test input"
      )

    # Verify we get an error
    assert Pattern.error?(result)

    # Use map_error to transform the error - handle actual error format
    transformed =
      Pattern.map_error(result, fn error ->
        "Workflow failed: #{inspect(error)}"
      end)

    assert Pattern.error?(transformed)

    # Verify error message was transformed
    {:error, error_msg} = transformed
    assert is_binary(error_msg)
    assert error_msg =~ "Workflow failed"
    assert error_msg =~ "ProcessorAgent"

    # Test successful case with all agents
    success_result =
      ConditionalWorkflow.execute(
        agents: agents_map,
        initial_input: "Valid input"
      )

    # Use Pattern.then for chaining with error propagation
    final_result =
      success_result
      |> Pattern.then(fn results ->
        assert Map.has_key?(results, :validate)
        {:ok, :chain_success}
      end)
      |> Pattern.then(fn status ->
        assert status == :chain_success
        {:ok, :final_success}
      end)

    assert Pattern.ok?(final_result)
    assert Pattern.unwrap!(final_result) == :final_success

    # Test error propagation with Pattern.then
    error_result = {:error, :test_error}

    propagated =
      error_result
      |> Pattern.then(fn _ -> {:ok, :should_not_execute} end)
      |> Pattern.then(fn _ -> {:ok, :should_not_execute_either} end)

    # Error should propagate without executing the functions
    assert Pattern.error?(propagated)
    assert propagated == {:error, :test_error}
  end
end
