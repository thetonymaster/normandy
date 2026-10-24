defmodule Normandy.Test.Hooks do
  @moduledoc """
  Hook test helpers. Hook opts must be plain data (they are saved in config templates and
  checked at `BaseAgent.init/1`), so a test names its process instead of passing a pid:
  `sink/0` registers the calling process under a unique name, once, and returns the name.
  """

  @spec sink() :: atom()
  def sink do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _unregistered ->
        name = :"normandy_hook_sink_#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end
end

defmodule Normandy.Test.Hooks.Probe do
  @moduledoc """
  A hook implementing every event. Each call sends `{:hook, tag, event, args}` to
  `opts[:notify]` (a registered name; omitted = no message) and returns
  `opts[:returns][event]`, or passes (`{:cont, value}`, `:cont`, `:ok`).
  `returns: [on_prompt: {:raise, "boom"}]` raises a RuntimeError, `{:exit, reason}` exits,
  `{:throw, value}` throws. `tag` defaults to the module.
  """
  use Normandy.Behaviours.Hooks

  @impl true
  def on_session_start(ctx, opts), do: report(:on_session_start, [ctx], opts, :ok)
  @impl true
  def on_passivate(ctx, opts), do: report(:on_passivate, [ctx], opts, :ok)
  @impl true
  def on_prompt(input, ctx, opts), do: report(:on_prompt, [input, ctx], opts, {:cont, input})
  @impl true
  def before_llm(info, ctx, opts), do: report(:before_llm, [info, ctx], opts, :cont)
  @impl true
  def before_tool(call, ctx, opts), do: report(:before_tool, [call, ctx], opts, {:cont, call})

  @impl true
  def after_tool(call, result, ctx, opts),
    do: report(:after_tool, [call, result, ctx], opts, {:cont, result})

  @impl true
  def after_compact(dropped, meta, ctx, opts),
    do: report(:after_compact, [dropped, meta, ctx], opts, :ok)

  @impl true
  def on_turn_end(outcome, ctx, opts), do: report(:on_turn_end, [outcome, ctx], opts, :ok)

  defp report(event, args, opts, default) do
    if dest = opts[:notify],
      do: send(dest, {:hook, Keyword.get(opts, :tag, __MODULE__), event, args})

    case Keyword.fetch(Keyword.get(opts, :returns, []), event) do
      {:ok, {:raise, message}} -> raise message
      {:ok, {:exit, reason}} -> exit(reason)
      {:ok, {:throw, value}} -> throw(value)
      {:ok, ret} -> ret
      :error -> default
    end
  end
end

defmodule Normandy.Test.Hooks.TurnEndOnly do
  @moduledoc "Implements only on_turn_end; sends {:turn_end_only, outcome} to opts[:notify]."
  use Normandy.Behaviours.Hooks

  @impl true
  def on_turn_end(outcome, _ctx, opts) do
    if dest = opts[:notify], do: send(dest, {:turn_end_only, outcome})
    :ok
  end
end

defmodule Normandy.Test.Hooks.PromptOnly do
  @moduledoc """
  Implements only on_prompt, so a turn opens exactly one hook span for it. Sends
  `{:prompt_only, input}` to `opts[:notify]` (a registered name) and returns
  `opts[:returns]`, or passes (`{:cont, input}`).
  """
  use Normandy.Behaviours.Hooks

  @impl true
  def on_prompt(input, _ctx, opts) do
    if dest = opts[:notify], do: send(dest, {:prompt_only, input})
    Keyword.get(opts, :returns, {:cont, input})
  end
end
