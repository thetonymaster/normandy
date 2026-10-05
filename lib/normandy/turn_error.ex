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
  # A worker's exit reason as a TurnError; an {exception, stacktrace} reason keeps the
  # exception and drops the stacktrace.
  @spec task_down(term()) :: t()
  def task_down({exception, stacktrace}) when is_exception(exception) and is_list(stacktrace),
    do: %__MODULE__{type: :task_down, reason: exception}

  def task_down(reason), do: %__MODULE__{type: :task_down, reason: reason}

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

  # The module of an exception, the tag of a tagged tuple, an atom as is; never a value.
  defp describe(%module{}), do: inspect(module)
  defp describe(atom) when is_atom(atom), do: inspect(atom)
  defp describe({kind, _}) when kind in [:exit, :throw], do: Atom.to_string(kind)

  defp describe(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: "{#{inspect(elem(tuple, 0))}, ...}"

  defp describe(_term), do: "a term"
end
