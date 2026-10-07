defmodule Normandy.TurnError do
  @moduledoc """
  A turn that failed for a reason that is not the model, the input or a guardrail.

  `Turn.Server.run/2`, `Turn.Session.run/2` and `AgentProcess.run/3` return
  `{:error, exception}`. The exception is Normandy's own (`Normandy.LLMError`,
  `Normandy.Schema.ValidationError`, `Normandy.Guardrails.ViolationError`,
  `Normandy.HookHaltError`, `Normandy.ModelCatalogError`) when that is what failed, and a
  `TurnError` otherwise.

  `AgentProcess` differs by turn engine for any other raised exception (a bug, not a
  Normandy error). With `turn_engine: :server` it is replied as a `:task_down`
  `TurnError`. In inline mode (the default) `run/3` and `cast/3` reply that exception
  bare, as `{:error, exception}`, rather than wrapping it. In both modes the turn runs
  in a worker process: an exit or a throw in it, or the worker killed from outside, is a
  `:task_down` `TurnError`.

  `:type` says which:

    * `:handler_crashed` - a handler or hook raised, exited or threw; `:handler` names it
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`, `:admit`, `:after_tool`,
      `:before_llm`, `:after_compact`, `:on_session_start`); `:reason` is the exception,
      or the raw exit reason or thrown term (normalized by `Exception.normalize/3`, so
      the kind is not kept)
    * `:persist_failed` - the session store rejected a write; `:reason` is its reason, or
      `{:store_exit, exit_reason}` when the store call exited (a call timeout, a dead store
      process): the exit reason with no stacktrace and a call's arguments replaced by
      their count, `{:timeout, {GenServer, :call, 3}}`. `Turn.Session.delete/1` returns it
      when the store refused the delete or its call exited, with the reason reduced to its
      tags (`{:store_exit, {:timeout, {GenServer, :call, "a list"}}}`)
    * `:approval_timeout` - nobody approved in time and `on_approval_timeout: :fail`;
      `:reason` is the list of tool call ids
    * `:task_down` - the LLM call, the compactor or the tool dispatch raised an exception
      that is not one of the above, or its worker stopped; `:reason` is the exception or
      the exit reason
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure. A session
      store's own reason is reduced to its tags: atoms and integers are kept, tuples are
      walked, an exception becomes its module, and any other term becomes a description of
      its type (`{:query_failed, "a map"}`). A load that raised, exited or threw gives the
      exception (an exit's or a throw's reason).
      `Turn.Session.approve/2` returns it with `reason: :no_session` when no server is live;
      `Turn.Session.delete/1` returns it when the registry cannot answer or the live server
      is not the supervisor's (`reason: {:not_stopped, :not_found}`)
    * `:queue_full` - `Normandy.Coordination.AgentProcess` refused a run or cast because
      `:max_pending_runs` runs and casts were already queued or in flight; `:reason` is
      that limit. Nothing ran
    * `:unexpected_event`, `:unresumable_state` - a persisted turn that can't continue, or
      a Normandy bug; `:reason` describes it

  A `TurnError` never carries a stacktrace; Normandy logs it where the failure happened.
  Its message names the failure but not values from it (they can hold the config or user
  data); read `:reason` for those.

  ## `:reason` in replies, in the store and in telemetry

  The `TurnError` replied to the caller holds the full `:reason`, a non-Normandy exception
  included, except a session store's reason (see `:session_unavailable` above). The copy
  `Turn.Server` persists as a failed turn's `Turn.State.error`, and every telemetry
  `:exception` `reason`, are redacted: a `:reason` that is an exception other than
  Normandy's own (a `KeyError`, a `MatchError`) is `%{exception: KeyError}`,
  because its fields and its message can hold the value it failed on, and a bare one is
  emitted as `%TurnError{type: :task_down, reason: %{exception: KeyError}}`. The same
  holds for such an exception at any depth of the tuples and lists in a reason. A call in
  an exit reason keeps its arity in place of its arguments, which hold the call's message:
  `{%KeyError{}, {GenServer, :call, [server, message, 5000]}}` is
  `{%{exception: KeyError}, {GenServer, :call, 3}}`. Normandy's own exceptions, and the
  rest of a reason (an exit reason's other terms, a thrown term, a store reason, tool
  call ids), are kept.
  """

  require Logger

  @types [
    :handler_crashed,
    :persist_failed,
    :approval_timeout,
    :task_down,
    :session_unavailable,
    :queue_full,
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
          | :queue_full
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

  def message(%__MODULE__{type: :queue_full, reason: limit}),
    do: "turn refused: queue full: #{inspect(limit)} run(s) already pending"

  def message(%__MODULE__{type: type, reason: reason}),
    do:
      "turn failed: #{type |> Atom.to_string() |> String.replace("_", " ")} (#{describe(reason)})"

  @doc false
  # True for the exceptions run/2,3 returns instead of raising.
  @spec domain?(Exception.t()) :: boolean()
  def domain?(%module{}), do: module in @domain

  @doc false
  # The form of a failure that is persisted (Turn.State.error) or emitted (every
  # telemetry :exception reason, see Normandy.Telemetry.Span.exception_metadata/3):
  # Normandy's own exceptions unchanged, any other exception (a bug) reduced to
  # %{exception: Module}, because its fields and its message can hold the value it
  # failed on. A bare one becomes the :task_down TurnError from_reason/1 would make of
  # it; a TurnError keeps its type and handler and has its reason reduced the same way,
  # nested TurnErrors included. Tuples and lists (an exit reason) are walked, so a
  # non-domain exception is reduced at any depth. A call in an exit reason,
  # {reason, {module, function, args}}, keeps its arity in place of its arguments
  # (a GenServer.call's message). Other terms (maps, structs) are kept. Stacktraces are
  # not dropped here: see drop_stacktraces/1. Idempotent.
  @spec redact(term()) :: term()
  def redact(%__MODULE__{reason: reason} = error), do: %{error | reason: redact_reason(reason)}

  def redact(exception) when is_exception(exception),
    do: if(domain?(exception), do: exception, else: redact(task_down(exception)))

  def redact(term), do: redact_reason(term)

  defp redact_reason(%__MODULE__{} = error), do: redact(error)

  defp redact_reason(%module{} = exception) when is_exception(exception),
    do: if(domain?(exception), do: exception, else: %{exception: module})

  # An exit from a call ({reason, {GenServer, :call, [server, message, timeout]}}): the
  # message can hold the caller's data, so the call keeps its arity only.
  defp redact_reason({reason, {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {redact_reason(reason), {module, function, length(args)}}

  defp redact_reason(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_list() |> List.to_tuple()

  defp redact_reason(list) when is_list(list), do: redact_list(list)

  defp redact_reason(term), do: term

  # Walks a list, an improper one included (its tail is redacted as a term).
  defp redact_list([head | tail]), do: [redact_reason(head) | redact_list(tail)]
  defp redact_list([]), do: []
  defp redact_list(tail), do: redact_reason(tail)

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

  def from_reason({:queue_full, limit}), do: %__MODULE__{type: :queue_full, reason: limit}

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
  # A raised failure for a log line: the exception's module for an :error (a raw Erlang
  # error normalized first), the kind ("exit", "throw") otherwise, then the stacktrace
  # with arities only. Never
  # the exception's message, a thrown term or an exit reason: each can hold the value it
  # failed on (a KeyError's map, a MatchError's term, a GenServer.call exit's message).
  # Every log line Normandy writes for a raise, exit or throw uses it.
  @spec format_raised(:error | :exit | :throw, term(), Exception.stacktrace()) :: String.t()
  def format_raised(kind, reason, stacktrace),
    do: describe_raised(kind, reason, stacktrace) <> "\n" <> format_stacktrace(stacktrace)

  @doc false
  # format_raised/3 without the stacktrace, for a one-line log (a retry warning).
  @spec describe_raised(:error | :exit | :throw, term(), Exception.stacktrace()) :: String.t()
  def describe_raised(:error, reason, stacktrace) do
    %module{} = Exception.normalize(:error, reason, stacktrace)
    inspect(module)
  end

  def describe_raised(kind, _reason, _stacktrace) when kind in [:exit, :throw],
    do: Atom.to_string(kind)

  @doc false
  # For a boundary that replies a raised bug instead of crashing (AgentProcess, Reactive,
  # a workflow step): logs `who` and format_raised/3, and returns {:error, exception}.
  # The stacktrace is never returned.
  @spec log_raised(String.t(), Exception.t(), Exception.stacktrace()) ::
          {:error, Exception.t()}
  def log_raised(who, exception, stacktrace) do
    Logger.error("#{who} raised " <> format_raised(:error, exception, stacktrace))
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
