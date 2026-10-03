defmodule NormandyTest.E2E.RunnerTest do
  use ExUnit.Case, async: true

  alias NormandyTest.E2E.Runner

  @moduletag :tmp_dir

  test "discover lists numbered scenarios in order and splits id from name", %{tmp_dir: dir} do
    for f <- ["02_tool_loop.exs", "01_long_conversation.exs", "support.exs", "README.md"],
        do: File.write!(Path.join(dir, f), "")

    assert [
             %{id: "01_long_conversation", name: "long_conversation"},
             %{id: "02_tool_loop", name: "tool_loop"}
           ] =
             Runner.discover(dir)
  end

  @all [
    %{
      id: "01_long_conversation",
      name: "long_conversation",
      path: "e2e/01_long_conversation.exs"
    },
    %{id: "02_compaction", name: "compaction", path: "e2e/02_compaction.exs"}
  ]

  test "select with no names runs everything" do
    assert {:ok, @all} = Runner.select(@all, [])
  end

  test "select matches by name or by id" do
    assert {:ok, [%{id: "02_compaction"}]} = Runner.select(@all, ["compaction"])
    assert {:ok, [%{id: "01_long_conversation"}]} = Runner.select(@all, ["01_long_conversation"])
  end

  test "select names an unknown scenario and lists the valid ones" do
    assert {:error, msg} = Runner.select(@all, ["compacton"])
    assert msg =~ "compacton"
    assert msg =~ "long_conversation"
    assert msg =~ "compaction"
  end

  test "parse_result reads the last E2E_RESULT line" do
    out =
      "noise\nE2E_RESULT {\"scenario\":\"x\",\"calls\":1,\"ms\":2}\nE2E_RESULT {\"scenario\":\"x\",\"calls\":7,\"ms\":900}\n"

    assert {:ok, %{calls: 7, ms: 900}} = Runner.parse_result(out)
  end

  test "parse_result is :missing when the scenario died before reporting" do
    assert :missing = Runner.parse_result("** (RuntimeError) boom\n")
  end

  test "preflight refuses to start without an API key" do
    assert {:error, msg} = Runner.preflight(nil, @all, fn -> :ok end)
    assert msg =~ "ANTHROPIC_API_KEY"
    assert {:error, _} = Runner.preflight("", @all, fn -> :ok end)
  end

  test "preflight blocks only the scenarios that need Postgres when it is down" do
    scenarios =
      @all ++ [%{id: "11_distributed", name: "distributed", path: "e2e/11_distributed.exs"}]

    down = fn -> {:error, "Postgres unreachable at localhost:5432"} end

    assert {:ok, %{blocked: blocked}} = Runner.preflight("sk-x", scenarios, down)
    assert blocked == %{"11_distributed" => "Postgres unreachable at localhost:5432"}
  end

  @tag :tmp_dir
  test "run_one passes a scenario that exits 0 and reports", %{tmp_dir: dir} do
    script = ~S|IO.puts(~s(E2E_RESULT {"scenario":"x","calls":2,"ms":5}))|

    result =
      Runner.run_one(%{id: "x", name: "x", path: "x"},
        report_dir: dir,
        timeout_ms: 30_000,
        command: {"elixir", ["-e", script]},
        echo: false
      )

    assert %{status: :pass, exit: 0, calls: 2} = result
    assert File.read!(result.log) =~ "E2E_RESULT"
  end

  @tag :tmp_dir
  test "run_one fails a scenario that exits non-zero without reporting", %{tmp_dir: dir} do
    result =
      Runner.run_one(%{id: "x", name: "x", path: "x"},
        report_dir: dir,
        timeout_ms: 30_000,
        command: {"elixir", ["-e", "System.halt(2)"]},
        echo: false
      )

    assert %{status: :fail, exit: 2, calls: nil} = result
  end

  @tag :tmp_dir
  test "run_one kills a scenario that exceeds its timeout", %{tmp_dir: dir} do
    result =
      Runner.run_one(%{id: "x", name: "x", path: "x"},
        report_dir: dir,
        timeout_ms: 1_500,
        command: {"elixir", ["-e", ":timer.sleep(:infinity)"]},
        echo: false
      )

    assert %{status: :timeout, calls: nil} = result
  end

  test "summary shows unknown call counts as ? and totals the known ones" do
    table =
      Runner.summary([
        %{id: "01_a", status: :pass, exit: 0, calls: 8, ms: 12_000, log: "l", reason: nil},
        %{id: "02_b", status: :fail, exit: 2, calls: nil, ms: 3_000, log: "l", reason: nil}
      ])

    assert table =~ "| 01_a | PASS | 0 | 8 | 12.0 |"
    assert table =~ "| 02_b | FAIL | 2 | ? | 3.0 |"
    assert table =~ "total live calls (known): 8"
  end
end
