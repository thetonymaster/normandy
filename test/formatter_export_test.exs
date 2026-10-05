defmodule Normandy.FormatterExportTest do
  use ExUnit.Case, async: true

  @dsl_modules [Normandy.DSL.Agent, Normandy.DSL.Workflow, Normandy.Schema]
  # Compiler hooks are never written by users.
  @not_user_macros [:__using__, :__before_compile__]

  test "every public DSL macro is exported without parens at every arity" do
    {opts, _} = Code.eval_file(".formatter.exs")
    exported = opts |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)

    for mod <- @dsl_modules,
        {name, arity} <- mod.__info__(:macros),
        name not in @not_user_macros do
      assert {name, arity} in exported, "#{inspect(mod)}.#{name}/#{arity} is not exported"
    end
  end
end
