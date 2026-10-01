defmodule Normandy.Tools.Executor do
  @moduledoc """
  Executes tools safely with timeout and error handling.

  The Executor provides a controlled environment for running tools with:
  - Timeout protection (`:timeout` option, else the tool struct's own `:timeout`
    field, else 30 s)
  - Error catching: a raise, exit, throw or timeout becomes `{:error, message}`
  - Result checking: a tool result that is not `{:ok, value}` or
    `{:error, reason}` becomes an error

  `:max_retries` re-runs a tool after any `{:error, _}`, including one it
  returned itself. A tool with side effects (sending mail, payments) then runs
  again, so leave it at 0 (the default) unless the tool is idempotent.

  Error messages reach the model as tool results, so an exit or throw is named
  by its tag only (its terms can carry call arguments), and an exception
  message is cut to 500 characters.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Telemetry.OtelCtx
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
    max_retries = max_retries!(opts)

    case Registry.get(registry, tool_name) do
      {:ok, tool} ->
        execute_with_retries(tool, max_retries, timeout!(opts, tool))

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
    execute_with_timeout(tool, timeout!(opts, tool))
  end

  @doc """
  Executes multiple tools in parallel.

  Returns a list of results in the same order as the input tools. Each spec is
  `{label, tool}`: the given tool instance is run (the label is only for the
  caller), so two instances of the same tool can run with different params. The
  registry argument is not consulted.

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
  def execute_parallel(_registry, tool_specs, opts \\ []) do
    parent_ctx = OtelCtx.capture()
    max_retries = max_retries!(opts)

    tool_specs
    |> Enum.map(fn {_label, tool} ->
      timeout = timeout!(opts, tool)

      Task.async(fn ->
        OtelCtx.restore(parent_ctx)
        execute_with_retries(tool, max_retries, timeout)
      end)
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

  # Precedence, for every entry point: the :timeout option, then the tool
  # struct's own :timeout field (a slow tool, such as a delegation to another
  # agent, can opt into a longer budget), then the default.
  defp timeout!(opts, tool) do
    timeout =
      case Keyword.fetch(opts, :timeout) do
        {:ok, value} -> value
        :error -> Map.get(tool, :timeout) || @default_timeout
      end

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError,
            "Normandy.Tools.Executor: :timeout must be a positive integer, got: #{inspect(timeout)}"
    end

    timeout
  end

  defp max_retries!(opts) do
    retries = Keyword.get(opts, :max_retries, @default_max_retries)

    unless is_integer(retries) and retries >= 0 do
      raise ArgumentError,
            "Normandy.Tools.Executor: :max_retries must be a non-negative integer, got: " <>
              inspect(retries)
    end

    retries
  end

  defp execute_with_retries(tool, retries_left, timeout) do
    case execute_with_timeout(tool, timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, _reason} when retries_left > 0 ->
        execute_with_retries(tool, retries_left - 1, timeout)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_with_timeout(tool, timeout) do
    parent_ctx = OtelCtx.capture()

    task =
      Task.async(fn ->
        OtelCtx.restore(parent_ctx)

        try do
          tool |> BaseTool.run() |> check_result()
        rescue
          error ->
            {:error, "Tool execution failed: #{error |> Exception.message() |> truncate()}"}
        catch
          :exit, reason ->
            {:error, "Tool execution exited: #{describe_reason(reason)}"}

          kind, reason ->
            {:error, "Tool execution failed (#{kind}): #{describe_reason(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        {:error, "Tool execution timeout after #{timeout}ms"}
    end
  end

  defp check_result({:ok, _value} = ok), do: ok
  defp check_result({:error, _reason} = error), do: error

  defp check_result(other) do
    {:error,
     "Tool returned an invalid result: expected {:ok, value} or {:error, reason}, got " <>
       Describe.type_of(other)}
  end

  defp describe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: inspect(elem(reason, 0))

  defp describe_reason(reason) when is_atom(reason), do: inspect(reason)
  defp describe_reason(reason), do: Describe.type_of(reason)

  # Characters, not bytes, so a multibyte character is never cut in half.
  @max_message 500
  defp truncate(message) do
    if String.length(message) <= @max_message,
      do: message,
      else: String.slice(message, 0, @max_message) <> "..."
  end
end
