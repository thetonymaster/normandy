defmodule Normandy.Coordination.Pattern do
  @moduledoc """
  Pattern matching utilities for agent results.

  Provides helper functions and macros to make working with agent results
  more ergonomic and expressive.

  ## Examples

      # Extract successful results
      {:ok, value} = Pattern.ok(agent_result)

      # Extract error reasons
      {:error, reason} = Pattern.error(agent_result)

      # Safe extraction with default
      value = Pattern.ok!(agent_result, default: "fallback")

      # Check result type
      true = Pattern.ok?(agent_result)
      false = Pattern.error?(agent_result)

      # Extract from multiple results
      successes = Pattern.filter_ok([result1, result2, result3])
      errors = Pattern.filter_errors([result1, result2, result3])

      # Transform results
      transformed = Pattern.map_ok(result, fn value -> String.upcase(value) end)

      # Chain operations
      final = result
        |> Pattern.map_ok(&String.trim/1)
        |> Pattern.map_ok(&String.upcase/1)
        |> Pattern.ok!(default: "EMPTY")
  """

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Returns true if the result is `{:ok, _}`.

  ## Examples

      iex> Normandy.Coordination.Pattern.ok?({:ok, "value"})
      true

      iex> Normandy.Coordination.Pattern.ok?({:error, "reason"})
      false
  """
  @spec ok?(result()) :: boolean()
  def ok?({:ok, _}), do: true
  def ok?(_), do: false

  @doc """
  Returns true if the result is `{:error, _}`.

  ## Examples

      iex> Normandy.Coordination.Pattern.error?({:error, "reason"})
      true

      iex> Normandy.Coordination.Pattern.error?({:ok, "value"})
      false
  """
  @spec error?(result()) :: boolean()
  def error?({:error, _}), do: true
  def error?(_), do: false

  @doc """
  Extracts the value from an `{:ok, value}` tuple.

  Returns the original result if not successful.

  ## Examples

      iex> Normandy.Coordination.Pattern.ok({:ok, "value"})
      {:ok, "value"}

      iex> Normandy.Coordination.Pattern.ok({:error, "reason"})
      {:error, "reason"}
  """
  @spec ok(result()) :: result()
  def ok(result), do: result

  @doc """
  Extracts the value from an `{:ok, value}` tuple or returns a default.

  ## Options

  - `:default` - Value to return if result is not `{:ok, value}` (default: nil)

  ## Examples

      iex> Normandy.Coordination.Pattern.ok!({:ok, "value"}, [])
      "value"

      iex> Normandy.Coordination.Pattern.ok!({:error, "reason"}, default: "fallback")
      "fallback"

      iex> Normandy.Coordination.Pattern.ok!({:error, "reason"}, [])
      nil
  """
  @spec ok!(result(), keyword()) :: term()
  def ok!(result, opts \\ [])
  def ok!({:ok, value}, _opts), do: value
  def ok!(_result, opts), do: Keyword.get(opts, :default)

  @doc """
  Extracts the error reason from an `{:error, reason}` tuple.

  Returns the original result if not an error.

  ## Examples

      iex> Normandy.Coordination.Pattern.error({:error, "reason"})
      {:error, "reason"}

      iex> Normandy.Coordination.Pattern.error({:ok, "value"})
      {:ok, "value"}
  """
  @spec error(result()) :: result()
  def error(result), do: result

  @doc """
  Extracts the error reason from an `{:error, reason}` tuple or returns a default.

  ## Options

  - `:default` - Value to return if result is not `{:error, reason}` (default: nil)

  ## Examples

      iex> Normandy.Coordination.Pattern.error!({:error, "reason"}, [])
      "reason"

      iex> Normandy.Coordination.Pattern.error!({:ok, "value"}, default: "no error")
      "no error"

      iex> Normandy.Coordination.Pattern.error!({:ok, "value"}, [])
      nil
  """
  @spec error!(result(), keyword()) :: term()
  def error!(result, opts \\ [])
  def error!({:error, reason}, _opts), do: reason
  def error!(_result, opts), do: Keyword.get(opts, :default)

  @doc """
  Filters a list of results to only include successful ones.

  Returns a list of values (without the `:ok` wrapper).

  ## Examples

      iex> results = [{:ok, 1}, {:error, "bad"}, {:ok, 2}, {:ok, 3}]
      iex> Normandy.Coordination.Pattern.filter_ok(results)
      [1, 2, 3]

      iex> Normandy.Coordination.Pattern.filter_ok([{:error, "bad"}, {:error, "worse"}])
      []
  """
  @spec filter_ok([result()]) :: [term()]
  def filter_ok(results) when is_list(results) do
    results
    |> Enum.filter(&ok?/1)
    |> Enum.map(fn {:ok, value} -> value end)
  end

  @doc """
  Filters a list of results to only include errors.

  Returns a list of error reasons (without the `:error` wrapper).

  ## Examples

      iex> results = [{:ok, 1}, {:error, "bad"}, {:ok, 2}, {:error, "worse"}]
      iex> Normandy.Coordination.Pattern.filter_errors(results)
      ["bad", "worse"]

      iex> Normandy.Coordination.Pattern.filter_errors([{:ok, 1}, {:ok, 2}])
      []
  """
  @spec filter_errors([result()]) :: [term()]
  def filter_errors(results) when is_list(results) do
    results
    |> Enum.filter(&error?/1)
    |> Enum.map(fn {:error, reason} -> reason end)
  end

  @doc """
  Transforms a successful result by applying a function to its value.

  Leaves error results unchanged.

  ## Examples

      iex> Normandy.Coordination.Pattern.map_ok({:ok, "hello"}, &String.upcase/1)
      {:ok, "HELLO"}

      iex> Normandy.Coordination.Pattern.map_ok({:error, "reason"}, &String.upcase/1)
      {:error, "reason"}
  """
  @spec map_ok(result(), (term() -> term())) :: result()
  def map_ok({:ok, value}, fun) when is_function(fun, 1) do
    {:ok, fun.(value)}
  end

  def map_ok(result, _fun), do: result

  @doc """
  Transforms an error result by applying a function to its reason.

  Leaves successful results unchanged.

  ## Examples

      iex> Normandy.Coordination.Pattern.map_error({:error, "reason"}, &String.upcase/1)
      {:error, "REASON"}

      iex> Normandy.Coordination.Pattern.map_error({:ok, "value"}, &String.upcase/1)
      {:ok, "value"}
  """
  @spec map_error(result(), (term() -> term())) :: result()
  def map_error({:error, reason}, fun) when is_function(fun, 1) do
    {:error, fun.(reason)}
  end

  def map_error(result, _fun), do: result

  @doc """
  Chains a function that returns a result to a successful result.

  If the input is `{:ok, value}`, applies the function to the value.
  If the input is an error, returns the error unchanged.

  This is similar to Elixir's `with` statement but for single results.

  ## Examples

      iex> alias Normandy.Coordination.Pattern
      iex> result = {:ok, "  hello  "}
      iex> result
      ...> |> Pattern.then(&{:ok, String.trim(&1)})
      ...> |> Pattern.then(&{:ok, String.upcase(&1)})
      {:ok, "HELLO"}

      iex> alias Normandy.Coordination.Pattern
      iex> result = {:error, "bad input"}
      iex> result
      ...> |> Pattern.then(&{:ok, String.trim(&1)})
      ...> |> Pattern.then(&{:ok, String.upcase(&1)})
      {:error, "bad input"}
  """
  @spec then(result(), (term() -> result())) :: result()
  def then({:ok, value}, fun) when is_function(fun, 1) do
    fun.(value)
  end

  def then(result, _fun), do: result

  @doc """
  Returns the first successful result from a list, or the last error if all failed.

  ## Examples

      iex> results = [{:error, "bad"}, {:ok, "good"}, {:ok, "also good"}]
      iex> Normandy.Coordination.Pattern.find_ok(results)
      {:ok, "good"}

      iex> results = [{:error, "bad"}, {:error, "worse"}, {:error, "worst"}]
      iex> Normandy.Coordination.Pattern.find_ok(results)
      {:error, "worst"}

      iex> Normandy.Coordination.Pattern.find_ok([])
      {:error, :no_results}
  """
  @spec find_ok([result()]) :: result()
  def find_ok([]), do: {:error, :no_results}

  def find_ok(results) when is_list(results) do
    Enum.find(results, List.last(results), &ok?/1)
  end

  @doc """
  Collects all successful results into a list.

  Returns `{:ok, list_of_values}` if at least one success, otherwise `{:error, list_of_reasons}`.

  ## Examples

      iex> results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      iex> Normandy.Coordination.Pattern.collect_ok(results)
      {:ok, [1, 2, 3]}

      iex> results = [{:ok, 1}, {:error, "bad"}, {:ok, 3}]
      iex> Normandy.Coordination.Pattern.collect_ok(results)
      {:ok, [1, 3]}

      iex> results = [{:error, "bad"}, {:error, "worse"}]
      iex> Normandy.Coordination.Pattern.collect_ok(results)
      {:error, ["bad", "worse"]}
  """
  @spec collect_ok([result()]) :: {:ok, [term()]} | {:error, [term()]}
  def collect_ok(results) when is_list(results) do
    successes = filter_ok(results)
    errors = filter_errors(results)

    if length(successes) > 0 do
      {:ok, successes}
    else
      {:error, errors}
    end
  end

  @doc """
  Returns `{:ok, list_of_values}` if all results are successful.

  Returns `{:error, list_of_reasons}` if any result is an error.

  ## Examples

      iex> results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      iex> Normandy.Coordination.Pattern.all_ok(results)
      {:ok, [1, 2, 3]}

      iex> results = [{:ok, 1}, {:error, "bad"}, {:ok, 3}]
      iex> Normandy.Coordination.Pattern.all_ok(results)
      {:error, ["bad"]}

      iex> results = [{:error, "bad"}, {:error, "worse"}]
      iex> Normandy.Coordination.Pattern.all_ok(results)
      {:error, ["bad", "worse"]}
  """
  @spec all_ok([result()]) :: {:ok, [term()]} | {:error, [term()]}
  def all_ok(results) when is_list(results) do
    errors = filter_errors(results)

    if length(errors) == 0 do
      {:ok, filter_ok(results)}
    else
      {:error, errors}
    end
  end

  @doc """
  Converts a map of results into a result of a map.

  Returns `{:ok, map_of_values}` if all results are successful.
  Returns `{:error, map_of_reasons}` if any result is an error.

  ## Examples

      iex> results = %{a: {:ok, 1}, b: {:ok, 2}, c: {:ok, 3}}
      iex> Normandy.Coordination.Pattern.all_ok_map(results)
      {:ok, %{a: 1, b: 2, c: 3}}

      iex> results = %{a: {:ok, 1}, b: {:error, "bad"}, c: {:ok, 3}}
      iex> Normandy.Coordination.Pattern.all_ok_map(results)
      {:error, %{b: "bad"}}
  """
  @spec all_ok_map(%{term() => result()}) ::
          {:ok, %{term() => term()}} | {:error, %{term() => term()}}
  def all_ok_map(results) when is_map(results) do
    {successes, errors} =
      Enum.reduce(results, {%{}, %{}}, fn {key, result}, {ok_acc, err_acc} ->
        case result do
          {:ok, value} -> {Map.put(ok_acc, key, value), err_acc}
          {:error, reason} -> {ok_acc, Map.put(err_acc, key, reason)}
        end
      end)

    if map_size(errors) == 0 do
      {:ok, successes}
    else
      {:error, errors}
    end
  end

  @doc """
  Unwraps a result, raising an error if it's not successful.

  ## Examples

      iex> Normandy.Coordination.Pattern.unwrap!({:ok, "value"})
      "value"

      iex> Normandy.Coordination.Pattern.unwrap!({:error, "reason"})
      ** (RuntimeError) Unwrap failed: "reason"
  """
  @spec unwrap!(result()) :: term() | no_return()
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise("Unwrap failed: #{inspect(reason)}")

  @doc """
  Wraps a value in `{:ok, value}` if it's not already a result tuple.

  ## Examples

      iex> Normandy.Coordination.Pattern.wrap("value")
      {:ok, "value"}

      iex> Normandy.Coordination.Pattern.wrap({:ok, "value"})
      {:ok, "value"}

      iex> Normandy.Coordination.Pattern.wrap({:error, "reason"})
      {:error, "reason"}
  """
  @spec wrap(term()) :: result()
  def wrap({:ok, _} = result), do: result
  def wrap({:error, _} = result), do: result
  def wrap(value), do: {:ok, value}

  @doc """
  Applies a function and wraps the result in `{:ok, result}`.

  If the function raises an exception, returns `{:error, exception}`.

  ## Examples

      iex> Normandy.Coordination.Pattern.try_wrap(fn -> 1 + 1 end)
      {:ok, 2}

      iex> Normandy.Coordination.Pattern.try_wrap(fn -> raise "boom" end)
      {:error, %RuntimeError{message: "boom"}}
  """
  @spec try_wrap((-> term())) :: result()
  def try_wrap(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end
end
