defmodule Normandy.Behaviours.HooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Normandy.Behaviours.Hooks

  defmodule OnlyTurnEnd do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_turn_end(_outcome, _ctx, _opts), do: :ok
  end

  defmodule NoCallbacks do
    def unrelated, do: :ok
  end

  # Plain @behaviour, no `use`: only validate_entries!/2 sees the function-hook arity.
  defmodule FunctionHookArity do
    @behaviour Normandy.Behaviours.Hooks
    def before_tool(_config, call), do: {:cont, call}
  end

  defmodule ChecksOpts do
    use Normandy.Behaviours.Hooks

    @impl true
    def on_turn_end(_outcome, _ctx, _opts), do: :ok

    @impl true
    def validate_opts!(opts) do
      if Keyword.has_key?(opts, :on_error), do: raise("on_error leaked into validate_opts!")
      unless is_binary(opts[:label]), do: raise(ArgumentError, "label must be a string")
      :ok
    end
  end

  test "events/0 lists the eight event callbacks" do
    assert Hooks.events() == [
             on_session_start: 2,
             on_passivate: 2,
             on_prompt: 3,
             before_llm: 3,
             before_tool: 3,
             after_tool: 4,
             after_compact: 4,
             on_turn_end: 3
           ]
  end

  test "every callback is optional and the callbacks are exactly events/0 plus validate_opts!/1" do
    expected = Enum.sort(Hooks.events() ++ [validate_opts!: 1])
    assert Enum.sort(Hooks.behaviour_info(:optional_callbacks)) == expected
    assert Enum.sort(Hooks.behaviour_info(:callbacks)) == expected
  end

  test "Behaviours.Config has hooks: [] by default" do
    assert %Normandy.Behaviours.Config{}.hooks == []
  end

  test "accepts an empty list and well-formed entries" do
    assert :ok = Hooks.validate_entries!([])
    assert :ok = Hooks.validate_entries!([{OnlyTurnEnd, []}, {OnlyTurnEnd, on_error: :open}])
  end

  test "rejects a non-list" do
    assert_raise ArgumentError,
                 ~r/hooks must be a list of \{module, opts\} entries, got: :nope/,
                 fn -> Hooks.validate_entries!(:nope) end
  end

  test "rejects an entry that is not {module, keyword}" do
    assert_raise ArgumentError,
                 ~r/invalid hook entry Normandy\.Behaviours\.HooksTest\.OnlyTurnEnd: expected \{module, keyword_opts\}/,
                 fn -> Hooks.validate_entries!([OnlyTurnEnd]) end

    assert_raise ArgumentError, ~r/invalid hook entry/, fn ->
      Hooks.validate_entries!([{OnlyTurnEnd, %{}}])
    end
  end

  test "rejects an unknown :on_error" do
    assert_raise ArgumentError,
                 ~r/invalid :on_error for .*OnlyTurnEnd: expected :reraise, :open or :closed, got: :maybe/,
                 fn -> Hooks.validate_entries!([{OnlyTurnEnd, on_error: :maybe}]) end
  end

  test "rejects opts holding a pid, function or reference, at any depth and without loading" do
    for bad <- [self(), fn -> :ok end, make_ref()] do
      assert_raise ArgumentError, ~r/hook opts for .*OnlyTurnEnd must be plain data/, fn ->
        Hooks.validate_entries!([{OnlyTurnEnd, notify: bad}])
      end
    end

    assert_raise ArgumentError, ~r/must be plain data/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, sink: %{to: [self()]}}], load: false)
    end
  end

  test "rejects a module that is not available" do
    assert_raise ArgumentError, ~r/hook module Does.Not.Exist is not available/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, []}])
    end
  end

  test "rejects a module that exports none of the hook callbacks" do
    assert_raise ArgumentError, ~r/exports none of the hook callbacks/, fn ->
      Hooks.validate_entries!([{NoCallbacks, []}])
    end
  end

  test "rejects a module exporting an event name only with the wrong arity" do
    assert_raise ArgumentError,
                 ~r/exports before_tool\/2, but the hook callback is before_tool\/3/,
                 fn -> Hooks.validate_entries!([{FunctionHookArity, []}]) end
  end

  test "runs validate_opts!/1 without :on_error and names the hook when it fails" do
    assert :ok = Hooks.validate_entries!([{ChecksOpts, label: "x", on_error: :open}])

    assert_raise ArgumentError,
                 ~r/invalid opts for hook Normandy\.Behaviours\.HooksTest\.ChecksOpts: label must be a string/,
                 fn -> Hooks.validate_entries!([{ChecksOpts, []}]) end
  end

  test "load: false checks shape, :on_error and plain data only" do
    assert :ok = Hooks.validate_entries!([{Does.Not.Exist, []}], load: false)

    assert_raise ArgumentError, ~r/invalid :on_error/, fn ->
      Hooks.validate_entries!([{Does.Not.Exist, on_error: :x}], load: false)
    end
  end

  test "check_entries/1 returns the validation error as data" do
    assert Hooks.check_entries([{OnlyTurnEnd, []}]) == :ok

    assert Hooks.check_entries([{Does.Not.Exist, []}]) ==
             {:error, {:invalid_hooks, "hook module Does.Not.Exist is not available"}}
  end

  test "use raises for an event name with the wrong arity" do
    assert_raise ArgumentError,
                 ~r/on_prompt\/2 is not a hook callback: on_prompt takes 3 arguments/,
                 fn ->
                   Code.compile_string("""
                   defmodule Normandy.Behaviours.HooksTest.WrongArity do
                     use Normandy.Behaviours.Hooks
                     def on_prompt(input, _ctx), do: {:cont, input}
                   end
                   """)
                 end
  end

  test "use warns for a name close to an event's" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Normandy.Behaviours.HooksTest.Misspelled do
          use Normandy.Behaviours.Hooks
          def on_promt(input, _ctx, _opts), do: {:cont, input}
          def on_turn_end(_outcome, _ctx, _opts), do: :ok
        end
        """)
      end)

    assert warning =~ "on_promt is not a hook callback; did you mean on_prompt?"
  end
end
