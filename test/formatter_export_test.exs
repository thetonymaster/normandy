defmodule Normandy.FormatterExportTest do
  use ExUnit.Case, async: true

  @dsl_macros [
    {Normandy.DSL.Agent,
     ~w(agent name description model temperature max_tokens max_tool_concurrency system_prompt
        background steps output_instructions tool memory max_messages guardrails streaming_mode
        streaming_chunk_size hooks)a},
    {Normandy.DSL.Workflow, ~w(workflow step parallel race agent input transform when_result)a},
    {Normandy.Schema, ~w(schema io_schema field)a}
  ]

  test "every public DSL macro is exported without parens at every arity" do
    {opts, _} = Code.eval_file(".formatter.exs")
    exported = opts |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)

    for {mod, names} <- @dsl_macros, {name, arity} <- mod.__info__(:macros), name in names do
      assert {name, arity} in exported, "#{inspect(mod)}.#{name}/#{arity} is not exported"
    end
  end
end
