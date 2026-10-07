defmodule Normandy.Tools.Executor do
  @moduledoc """
  Runs one tool call safely: `c:Normandy.Tool.run/2` in a separate task, with a timeout and
  error handling.

  - The tool gets the `%Normandy.Tools.Context{}` passed as `:context`; its `input` is the
    call's validated input.
  - Timeout: `:timeout` milliseconds, default `default_timeout/0`. The dispatch pipeline
    passes the tool's registration timeout (`Normandy.Tools.Toolset.register/3`); a
    `:timeout` field on the tool struct is never read.
  - A raise, exit, throw or timeout becomes `{:error, message}`.
  - A result that is not `{:ok, value}` or `{:error, reason}` becomes an error.

  Error messages reach the model as tool results, so an exit or throw is named
  by its tag only (its terms can carry call arguments), an exception whose message
  shows the term it failed on (`KeyError`, `MatchError`, `CaseClauseError`,
  `Protocol.UndefinedError`, ...) is named by its module (a `KeyError` also by its key),
  and any other exception message is cut to 500 characters.

  ## No controls

  `execute_tool/2` and `execute_tool_classified/2` run the tool and nothing else: no
  policy, no approval, no hooks, no budget and no input validation. The agent loop runs
  tools through `Normandy.Agents.Dispatch`, which applies all of them; call these only for
  a tool and an input you have already checked.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Tool
  alias Normandy.Tools.Context

  @type execution_result :: {:ok, term()} | {:error, String.t()}
  @typedoc """
  What made a tool execution fail: the tool raised (or threw) (`:exception`),
  exited (`:exit`), ran past its timeout (`:timeout`), returned `{:error, _}`
  itself (`:tool_error`), or returned something else (`:invalid_result`).
  """
  @type error_type :: :exception | :exit | :timeout | :tool_error | :invalid_result
  @type execution_options :: [context: Context.t(), timeout: pos_integer()]

  @default_timeout 30_000

  @opts_schema NimbleOptions.new!(
                 context: [
                   type: :any,
                   type_doc: "a `Normandy.Tools.Context`",
                   required: true,
                   doc: "The call's `%Normandy.Tools.Context{}`, carrying the validated input."
                 ],
                 timeout: [
                   type: :pos_integer,
                   default: @default_timeout,
                   doc: "Milliseconds the tool may run before the call fails with a timeout."
                 ]
               )

  @doc "The timeout of a tool registered without `:timeout`, in milliseconds."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  Runs `tool` with the given context.

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute_tool(struct(), execution_options()) :: execution_result()
  def execute_tool(tool, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_tool, 2})
    {result, _error_type} = run_classified(tool, opts, "execute_tool/2")
    result
  end

  @doc """
  Like `execute_tool/2`, but also says why a failed execution failed (see
  `t:error_type/0`); the error type is `nil` on success. The `{:error, message}`
  result is exactly the one `execute_tool/2` returns.
  """
  @spec execute_tool_classified(struct(), execution_options()) ::
          {{:ok, term()}, nil} | {{:error, String.t()}, error_type()}
  def execute_tool_classified(tool, opts \\ []) do
    opts =
      Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_tool_classified, 2})

    run_classified(tool, opts, "execute_tool_classified/2")
  end

  defp run_classified(tool, opts, function) do
    context = context!(Keyword.fetch!(opts, :context), function)
    execute_with_timeout(tool, Keyword.fetch!(opts, :timeout), context)
  end

  defp context!(%Context{} = context, _function), do: context

  defp context!(other, function) do
    raise ArgumentError,
          "Normandy.Tools.Executor.#{function}: :context must be a %Normandy.Tools.Context{}, " <>
            "got: #{Describe.type_of(other)}"
  end

  defp execute_with_timeout(tool, timeout, context) do
    parent_ctx = OtelCtx.capture()

    task =
      Task.async(fn ->
        OtelCtx.restore(parent_ctx)

        try do
          tool |> Tool.run(context) |> check_result()
        rescue
          error ->
            {{:error, "Tool execution failed: #{describe_exception(error)}"}, :exception}
        catch
          :exit, reason ->
            {{:error, "Tool execution exited: #{describe_reason(reason)}"}, :exit}

          kind, reason ->
            {{:error, "Tool execution failed (#{kind}): #{describe_reason(reason)}"}, :exception}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, classified} ->
        classified

      nil ->
        {{:error, "Tool execution timeout after #{timeout}ms"}, :timeout}
    end
  end

  defp check_result({:ok, _value} = ok), do: {ok, nil}
  defp check_result({:error, _reason} = error), do: {error, :tool_error}

  defp check_result(other) do
    {{:error,
      "Tool returned an invalid result: expected {:ok, value} or {:error, reason}, got " <>
        Describe.type_of(other)}, :invalid_result}
  end

  defp describe_reason(reason), do: Describe.reason_tag(reason)

  # Exceptions whose message inspects the term they failed on, which can be a struct
  # holding a token or the tool's whole input: named by module (and a KeyError's key).
  @term_exceptions [
    BadArityError,
    BadBooleanError,
    BadFunctionError,
    BadMapError,
    BadStructError,
    CaseClauseError,
    MatchError,
    Protocol.UndefinedError,
    TryClauseError,
    WithClauseError
  ]

  defp describe_exception(%KeyError{key: key}),
    do: "KeyError: key #{inspect(key, limit: 5, printable_limit: 50)} not found"

  # An Erlang error's message inspects its whole original term: named by that term's tag.
  defp describe_exception(%ErlangError{original: original}),
    do: "ErlangError: #{Describe.reason_tag(original)}"

  defp describe_exception(%mod{}) when mod in @term_exceptions, do: inspect(mod)
  defp describe_exception(error), do: error |> Exception.message() |> truncate()

  # Characters, not bytes, so a multibyte character is never cut in half.
  @max_message 500
  defp truncate(message) do
    if String.length(message) <= @max_message,
      do: message,
      else: String.slice(message, 0, @max_message) <> "..."
  end
end
