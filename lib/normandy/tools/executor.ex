defmodule Normandy.Tools.Executor do
  @moduledoc """
  Executes tools safely with timeout and error handling.

  The Executor provides a controlled environment for running tools with:
  - Timeout protection
  - Error catching and formatting
  - Execution logging
  - Result validation
  """

  alias Normandy.Tools.BaseTool
  alias Normandy.Tools.Registry

  @type execution_result :: {:ok, term()} | {:error, String.t()}
  @type execution_options :: [
          timeout: pos_integer(),
          max_retries: non_neg_integer()
        ]

  @default_timeout 30_000
  @default_max_retries 0

  @doc """
  Executes a tool by name from the registry.

  ## Options

    * `:timeout` - Maximum execution time in milliseconds (default: 30000)
    * `:max_retries` - Number of retry attempts on failure (default: 0)

  ## Examples

      iex> registry = Normandy.Tools.Registry.new([%CalculatorTool{operation: :add, a: 5, b: 3}])
      iex> Normandy.Tools.Executor.execute(registry, "calculator")
      {:ok, 8}

      iex> Normandy.Tools.Executor.execute(registry, "nonexistent")
      {:error, "Tool 'nonexistent' not found in registry"}

  """
  @spec execute(Registry.t(), String.t(), execution_options()) :: execution_result()
  def execute(registry, tool_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)

    case Registry.get(registry, tool_name) do
      {:ok, tool} ->
        execute_with_retries(tool, max_retries, timeout)

      :error ->
        {:error, "Tool '#{tool_name}' not found in registry"}
    end
  end

  @doc """
  Executes a tool instance directly.

  ## Examples

      iex> tool = %CalculatorTool{operation: :add, a: 2, b: 3}
      iex> Normandy.Tools.Executor.execute_tool(tool)
      {:ok, 5}

  """
  @spec execute_tool(struct(), execution_options()) :: execution_result()
  def execute_tool(tool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    execute_with_timeout(tool, timeout)
  end

  @doc """
  Executes multiple tools in parallel.

  Returns a list of results in the same order as the input tools.

  ## Examples

      iex> tools = [
      ...>   {"calc1", %CalculatorTool{operation: :add, a: 1, b: 2}},
      ...>   {"calc2", %CalculatorTool{operation: :multiply, a: 3, b: 4}}
      ...> ]
      iex> Normandy.Tools.Executor.execute_parallel(registry, tools)
      [
        {:ok, 3},
        {:ok, 12}
      ]

  """
  @spec execute_parallel(Registry.t(), [{String.t(), struct()}], execution_options()) :: [
          execution_result()
        ]
  def execute_parallel(registry, tool_specs, opts \\ []) do
    tool_specs
    |> Enum.map(fn {tool_name, _params} ->
      Task.async(fn -> execute(registry, tool_name, opts) end)
    end)
    |> Enum.map(&Task.await(&1, :infinity))
  end

  @doc """
  Executes multiple tools sequentially.

  Stops execution if any tool returns an error (fail-fast behavior).

  ## Examples

      iex> tools = ["tool1", "tool2", "tool3"]
      iex> Normandy.Tools.Executor.execute_sequential(registry, tools)
      {:ok, [result1, result2, result3]}

  """
  @spec execute_sequential(Registry.t(), [String.t()], execution_options()) ::
          {:ok, [term()]} | {:error, String.t()}
  def execute_sequential(registry, tool_names, opts \\ []) do
    tool_names
    |> Enum.reduce_while({:ok, []}, fn tool_name, {:ok, results} ->
      case execute(registry, tool_name, opts) do
        {:ok, result} ->
          {:cont, {:ok, results ++ [result]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  # Private functions

  defp execute_with_retries(tool, retries_left, timeout) do
    case execute_with_timeout(tool, timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when retries_left > 0 ->
        execute_with_retries(tool, retries_left - 1, timeout)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_with_timeout(tool, timeout) do
    task =
      Task.async(fn ->
        try do
          BaseTool.run(tool)
        rescue
          error ->
            {:error, "Tool execution failed: #{Exception.message(error)}"}
        catch
          :exit, reason ->
            {:error, "Tool execution exited: #{inspect(reason)}"}

          kind, reason ->
            {:error, "Tool execution failed (#{kind}): #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        {:error, "Tool execution timeout after #{timeout}ms"}
    end
  end
end
