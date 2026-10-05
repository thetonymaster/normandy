defmodule Normandy.TurnError do
  @moduledoc """
  A turn that failed for a reason that is not the model, the input or a guardrail.

  `Turn.Server.run/2`, `Turn.Session.run/2` and `AgentProcess.run/3` return
  `{:error, exception}`. The exception is Normandy's own (`Normandy.LLMError`,
  `Normandy.Schema.ValidationError`, `Normandy.Guardrails.ViolationError`,
  `Normandy.HookHaltError`, `Normandy.ModelCatalogError`) when that is what failed, and a
  `TurnError` otherwise. `:type` says which:

    * `:handler_crashed` - a handler or hook raised, exited or threw; `:handler` names it
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`, `:admit`, `:after_tool`,
      `:before_llm`, `:after_compact`, `:on_session_start`); `:reason` is the exception,
      or the raw exit reason or thrown term (normalized by `Exception.normalize/3`, so
      the kind is not kept)
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason
    * `:approval_timeout` - nobody approved in time and `on_approval_timeout: :fail`;
      `:reason` is the list of tool call ids
    * `:task_down` - the LLM call, the compactor or the tool dispatch raised an exception
      that is not one of the above, or its worker stopped; `:reason` is the exception or
      the exit reason
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure
    * `:unexpected_event`, `:unresumable_state` - a persisted turn that can't continue, or
      a Normandy bug; `:reason` describes it

  A `TurnError` never carries a stacktrace; Normandy logs it where the failure happened.
  Its message names the failure but not values from it (they can hold the config or user
  data); read `:reason` for those.
  """

  require Logger

  @types [
    :handler_crashed,
    :persist_failed,
    :approval_timeout,
    :task_down,
    :session_unavailable,
    :unexpected_event,
    :unresumable_state
  ]

  # Normandy's failure exceptions: run/2,3 returns them, Turn.Server replies them bare.
  @domain [
    Normandy.LLMError,
    Normandy.Schema.ValidationError,
    Normandy.Guardrails.ViolationError,
    Normandy.HookHaltError,
    Normandy.ModelCatalogError,
    __MODULE__
  ]

  defexception [:type, :handler, :reason]

  @type type ::
          :handler_crashed
          | :persist_failed
          | :approval_timeout
          | :task_down
          | :session_unavailable
          | :unexpected_event
          | :unresumable_state

  @type t :: %__MODULE__{type: type(), handler: atom() | nil, reason: term()}

  @impl true
  def exception(fields) when is_list(fields) do
    type = Keyword.get(fields, :type)

    unless type in @types do
      raise ArgumentError,
            "Normandy.TurnError: unknown :type #{inspect(type)}, expected one of #{inspect(@types)}"
    end

    struct!(__MODULE__, fields)
  end

  @impl true
  def message(%__MODULE__{type: :handler_crashed, handler: handler, reason: reason}),
    do: "turn failed: handler crashed: #{inspect(handler)} (#{describe(reason)})"

  def message(%__MODULE__{type: :persist_failed, reason: reason}),
    do: "turn failed: persist failed: the session store rejected a write (#{describe(reason)})"

  def message(%__MODULE__{type: :approval_timeout, reason: ids}) when is_list(ids),
    do: "turn failed: approval timeout: #{length(ids)} tool call(s) not approved in time"

  def message(%__MODULE__{type: :task_down, reason: reason}),
    do: "turn failed: task down: the turn's worker failed (#{describe(reason)})"

  def message(%__MODULE__{type: :session_unavailable, reason: reason}),
    do: "session unavailable: the session could not be started (#{describe(reason)})"

  def message(%__MODULE__{type: type, reason: reason}),
    do:
      "turn failed: #{type |> Atom.to_string() |> String.replace("_", " ")} (#{describe(reason)})"

  @doc false
  # True for the exceptions run/2,3 returns instead of raising.
  @spec domain?(Exception.t()) :: boolean()
  def domain?(%module{}), do: module in @domain

  @doc false
  # A worker's exit reason as a TurnError, with every stacktrace dropped from it: a
  # raise's {exception, stacktrace} keeps the exception, a throw's
  # {{:nocatch, value}, stacktrace} keeps {:nocatch, value}, an Erlang error's
  # {reason, stacktrace} keeps the reason, and tuples nested in the reason (a
  # GenServer.call exit, a caught {kind, reason}) are stripped the same way.
  @spec task_down(term()) :: t()
  def task_down(reason), do: %__MODULE__{type: :task_down, reason: drop_stacktraces(reason)}

  @doc false
  # The exception a failed turn returns, from a failure reason of the Turn core or
  # Turn.Server (decision 15b): Normandy's own exceptions bare, anything else a
  # TurnError. Never a tagged tuple, never a stacktrace.
  @spec from_reason(term()) :: Exception.t()
  def from_reason({:rejected, exception}) when is_exception(exception), do: exception
  def from_reason({:hook_halted, exception}) when is_exception(exception), do: exception

  def from_reason({:handler_crashed, name, reason}),
    do: %__MODULE__{type: :handler_crashed, handler: name, reason: drop_stacktraces(reason)}

  def from_reason({:persist_failed, reason}),
    do: %__MODULE__{type: :persist_failed, reason: reason}

  def from_reason({:approval_timeout, ids}), do: %__MODULE__{type: :approval_timeout, reason: ids}

  # A domain exception the worker died with is replied bare, like one it returned.
  def from_reason({:task_down, reason}) do
    case task_down(reason) do
      %__MODULE__{reason: exception} = error when is_exception(exception) ->
        if domain?(exception), do: exception, else: error

      error ->
        error
    end
  end

  def from_reason({:unexpected_event, _state, _event} = reason),
    do: %__MODULE__{type: :unexpected_event, reason: reason}

  def from_reason({:unresumable_state, status}),
    do: %__MODULE__{type: :unresumable_state, reason: status}

  def from_reason(exception) when is_exception(exception),
    do: if(domain?(exception), do: exception, else: task_down(exception))

  def from_reason(other) do
    raise ArgumentError,
          "Normandy.TurnError.from_reason/1: no exception for turn failure #{inspect(other)}; " <>
            "a new failure reason needs a clause here"
  end

  @doc false
  # A stacktrace for a log line: frames keep the arity, never the arguments (a
  # FunctionClauseError's top frame holds them, and one may be the config).
  @spec format_stacktrace(Exception.stacktrace()) :: String.t()
  def format_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
    |> Exception.format_stacktrace()
  end

  @doc false
  # For a boundary that replies a raised bug instead of crashing (AgentProcess, Reactive,
  # a workflow step): logs `who`, the exception's module and the stacktrace (arities
  # only), and returns {:error, exception}. The stacktrace is never returned.
  @spec log_raised(String.t(), Exception.t(), Exception.stacktrace()) ::
          {:error, Exception.t()}
  def log_raised(who, exception, stacktrace) do
    Logger.error(
      "#{who} raised #{inspect(exception.__struct__)}\n" <> format_stacktrace(stacktrace)
    )

    {:error, exception}
  end

  @doc false
  # `term` with every stacktrace in it dropped: a {reason, stacktrace} tuple becomes
  # reason, at any depth of nested tuples. Exceptions and other non-tuple terms are kept
  # whole (an exception's own fields are its author's); only tuples are walked. For a
  # failure reason that is persisted or replied before from_reason/1 sees it.
  @spec drop_stacktraces(term()) :: term()
  def drop_stacktraces({reason, stacktrace} = tuple) do
    if stacktrace?(stacktrace),
      do: drop_stacktraces(reason),
      else: {drop_stacktraces(reason), drop_stacktraces(elem(tuple, 1))}
  end

  def drop_stacktraces(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&drop_stacktraces/1) |> List.to_tuple()

  def drop_stacktraces(term), do: term

  # A non-empty list of {module, function, arity_or_args, location} or
  # {fun, arity_or_args, location} frames.
  defp stacktrace?([_ | _] = frames), do: Enum.all?(frames, &frame?/1)
  defp stacktrace?(_term), do: false

  defp frame?({mod, fun, args, location})
       when is_atom(mod) and is_atom(fun) and (is_integer(args) or is_list(args)) and
              is_list(location),
       do: true

  defp frame?({fun, args, location})
       when is_function(fun) and (is_integer(args) or is_list(args)) and is_list(location),
       do: true

  defp frame?(_term), do: false

  # The module of an exception, the tag of a tagged tuple, an atom as is; never a value.
  defp describe(%module{}), do: inspect(module)
  defp describe(atom) when is_atom(atom), do: inspect(atom)
  defp describe({kind, _}) when kind in [:exit, :throw], do: Atom.to_string(kind)

  defp describe(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: "{#{inspect(elem(tuple, 0))}, ...}"

  defp describe(_term), do: "a term"
end
