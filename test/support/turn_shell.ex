defmodule Normandy.Test.TurnShell do
  @moduledoc false
  # Drives a turn through Turn.Driver from plain functions, for tests that exercise the core
  # against a real Dispatch chokepoint without a BaseAgentConfig. It takes the deps map the
  # former Turn.Inline shell took and returns `{:ok, final_state}`; a turn the core fails
  # raises, as Turn.Driver does.
  #
  # `deps`:
  #   * `:call_llm` - `fn request -> {:ok, response} | {:error, exception} end` (required)
  #   * `:dispatch` - `fn calls -> [%ToolResult{}] end` (required)
  #   * `:append`, `:emit`, `:convert`, `:validate`, `:guard`, `:compact` - optional:
  #     `fn role, content`, `fn name, meta`, `fn raw, response_model`, `fn value`,
  #     `fn value`, `fn info`; the defaults do nothing (convert and validate return their
  #     input).
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver

  @spec run(Turn.State.t(), map()) :: {:ok, Turn.State.t()}
  def run(%Turn.State{} = state, deps) do
    deps =
      Map.merge(
        %{
          emit: fn _name, _meta -> :ok end,
          append: fn _role, _content -> :ok end,
          convert: fn raw, _response_model -> raw end,
          validate: fn value -> value end,
          guard: fn _value -> :ok end,
          compact: fn _info -> :ok end
        },
        deps
      )

    {_acc, final} = Driver.drive(state, handlers(deps), nil)
    {:ok, final}
  end

  defp handlers(deps) do
    %Driver.Handlers{
      call_llm: fn _acc, _state, request -> response!(deps.call_llm.(request)) end,
      dispatch_tools: fn _acc, calls -> deps.dispatch.(calls) end,
      convert: fn _acc, raw, response_model -> deps.convert.(raw, response_model) end,
      validate: fn _acc, value -> deps.validate.(value) end,
      guard: fn _acc, value -> deps.guard.(value) end,
      append: fn acc, role, content ->
        deps.append.(role, content)
        acc
      end,
      compact: fn acc, _state, info ->
        deps.compact.(info)
        {acc, %{}}
      end,
      emit: fn _acc, name, meta -> deps.emit.(name, meta) end
    }
  end

  defp response!({:ok, response}), do: response
  defp response!({:error, exception}) when is_exception(exception), do: raise(exception)
end
