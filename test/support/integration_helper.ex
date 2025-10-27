defmodule NormandyTest.Support.IntegrationHelper do
  @moduledoc """
  Helper functions for integration tests that use real Anthropic API.

  Provides utilities for:
  - API key management
  - Real client setup
  - Test skipping when API unavailable
  - Common assertions for integration tests
  """

  import ExUnit.Assertions

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Agents.BaseAgent

  @doc """
  Gets the Anthropic API key from environment.

  Checks both API_KEY (local) and ANTHROPIC_API_KEY (standard) env vars.
  """
  def get_api_key do
    System.get_env("API_KEY") || System.get_env("ANTHROPIC_API_KEY")
  end

  @doc """
  Checks if API key is available for testing.
  """
  def api_key_available? do
    get_api_key() != nil
  end

  @doc """
  Gets API key or raises clear error if not available.

  Tests marked with @tag :api will automatically be skipped when running
  `mix test --exclude api`. This function provides a clear error message
  if API key is missing when tests do run.

  ## Example

      setup do
        IntegrationHelper.ensure_api_key!()
        # ... test setup
      end
  """
  def ensure_api_key! do
    unless api_key_available?() do
      raise """
      API key not available for integration tests.

      To run integration tests, set one of:
        - API_KEY environment variable (local)
        - ANTHROPIC_API_KEY environment variable (standard)

      To skip integration tests, run:
        mix test --exclude api
      """
    end
  end

  @doc """
  Creates a real Claudio adapter client for testing.

  ## Options

  - `:enable_caching` - Enable prompt caching (default: true)
  - `:timeout` - Request timeout in ms (default: 60_000)
  - `:max_retries` - Max retry attempts (default: 3)

  ## Example

      client = IntegrationHelper.create_real_client()
  """
  def create_real_client(opts \\ []) do
    api_key = get_api_key()

    unless api_key do
      raise "API key required. Set API_KEY or ANTHROPIC_API_KEY environment variable."
    end

    %ClaudioAdapter{
      api_key: api_key,
      options: %{
        timeout: Keyword.get(opts, :timeout, 60_000),
        enable_caching: Keyword.get(opts, :enable_caching, true),
        max_retries: Keyword.get(opts, :max_retries, 3)
      }
    }
  end

  @doc """
  Creates an agent with real Claudio client for integration testing.

  ## Options

  - `:model` - Model to use (default: "claude-3-5-sonnet-20241022")
  - `:temperature` - Temperature (default: 0.7)
  - `:enable_caching` - Enable prompt caching (default: true)
  - `:retry_options` - Retry configuration
  - `:enable_circuit_breaker` - Enable circuit breaker (default: false)

  ## Example

      agent = IntegrationHelper.create_real_agent(temperature: 0.5)
  """
  def create_real_agent(opts \\ []) do
    client =
      create_real_client(
        enable_caching: Keyword.get(opts, :enable_caching, true),
        timeout: Keyword.get(opts, :timeout, 60_000)
      )

    config = %{
      client: client,
      model: Keyword.get(opts, :model, "claude-3-5-sonnet-20241022"),
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 1024),
      retry_options: Keyword.get(opts, :retry_options),
      enable_circuit_breaker: Keyword.get(opts, :enable_circuit_breaker, false),
      circuit_breaker_options: Keyword.get(opts, :circuit_breaker_options, [])
    }

    BaseAgent.init(config)
  end

  @doc """
  Runs a simple test conversation to verify API connectivity.

  Returns {:ok, response} or {:error, reason}.
  """
  def verify_api_connection do
    try do
      agent = create_real_agent()
      {_updated_agent, response} = BaseAgent.run(agent, %{chat_message: "Hello"})
      {:ok, response}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Asserts that a response contains expected content.

  ## Example

      assert_response_contains(response, "hello")
  """
  def assert_response_contains(response, expected_text) when is_map(response) do
    chat_message = Map.get(response, :chat_message)

    assert chat_message != nil, "Expected response to have chat_message"

    assert String.contains?(String.downcase(chat_message), String.downcase(expected_text)),
           "Expected response to contain '#{expected_text}', got: #{chat_message}"
  end

  @doc """
  Waits for an async operation to complete with timeout.

  ## Example

      result = wait_for(fn ->
        receive do
          {:result, r} -> {:ok, r}
        after
          0 -> :pending
        end
      end)
  """
  def wait_for(check_fn, timeout \\ 5000, interval \\ 100) do
    end_time = System.monotonic_time(:millisecond) + timeout

    do_wait_for(check_fn, end_time, interval)
  end

  defp do_wait_for(check_fn, end_time, interval) do
    case check_fn.() do
      {:ok, result} ->
        {:ok, result}

      :pending ->
        if System.monotonic_time(:millisecond) < end_time do
          Process.sleep(interval)
          do_wait_for(check_fn, end_time, interval)
        else
          {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Measures execution time of a function.

  Returns {duration_ms, result}.

  ## Example

      {duration, response} = measure_time(fn ->
        BaseAgent.run(agent, input)
      end)
  """
  def measure_time(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    {duration, result}
  end

  @doc """
  Creates a simple calculator tool for testing.
  """
  def create_calculator_tool do
    %Normandy.Tools.Examples.Calculator{
      operation: "add",
      a: 0,
      b: 0
    }
  end

  @doc """
  Creates a string manipulator tool for testing.
  """
  def create_string_tool do
    %Normandy.Tools.Examples.StringManipulator{
      operation: "uppercase",
      text: ""
    }
  end
end
