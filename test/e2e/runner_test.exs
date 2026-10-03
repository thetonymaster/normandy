defmodule NormandyTest.E2E.RunnerTest do
  use ExUnit.Case, async: true

  alias NormandyTest.E2E.Runner

  @moduletag :tmp_dir

  test "discover lists numbered scenarios in order and splits id from name", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "02_tool_loop.exs"), ~s|S.start("02_tool_loop", cap: 12)|)
    File.write!(Path.join(dir, "01_long_conversation.exs"), ~s|S.start("01_x", cap: 3)|)
    for f <- ["support.exs", "README.md"], do: File.write!(Path.join(dir, f), "")

    assert [
             %{id: "01_long_conversation", name: "long_conversation", cap: 3},
             %{id: "02_tool_loop", name: "tool_loop", cap: 12}
           ] =
             Runner.discover(dir)
  end

  test "discover leaves cap nil when a scenario declares none", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "01_bare.exs"), "IO.puts(:hi)")
    assert [%{id: "01_bare", cap: nil}] = Runner.discover(dir)
  end

  @all [
    %{
      id: "01_long_conversation",
      name: "long_conversation",
      path: "e2e/01_long_conversation.exs",
      cap: 12
    },
    %{id: "02_compaction", name: "compaction", path: "e2e/02_compaction.exs", cap: 18}
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

  test "parse_result names a malformed E2E_RESULT line instead of raising" do
    assert {:error, msg} = Runner.parse_result("E2E_RESULT {not json\n")
    assert msg =~ "malformed E2E_RESULT"
    assert {:error, _} = Runner.parse_result(~s|E2E_RESULT {"calls":1}\n|)
  end

  test "preflight refuses to start without an API key" do
    assert {:error, msg} = Runner.preflight(nil, @all, fn -> :ok end)
    assert msg =~ "ANTHROPIC_API_KEY"
    assert {:error, _} = Runner.preflight("", @all, fn -> :ok end)
  end

  test "preflight blocks only the scenarios that need Postgres when it is down" do
    scenarios =
      @all ++
        [%{id: "11_distributed", name: "distributed", path: "e2e/11_distributed.exs", cap: 6}]

    down = fn -> {:error, "Postgres unreachable at localhost:5432"} end

    assert {:ok, %{blocked: blocked}} = Runner.preflight("sk-x", scenarios, down)
    assert blocked == %{"11_distributed" => "Postgres unreachable at localhost:5432"}
  end

  test "preflight refuses a selection whose live-call caps exceed the suite cap" do
    big = Enum.map(1..8, &%{id: "0#{&1}_s", name: "s", path: "p", cap: 18})

    assert {:error, msg} = Runner.preflight("sk-x", big, fn -> :ok end)
    assert msg =~ "144"
    assert msg =~ "140"
  end

  test "preflight refuses a scenario that declares no live-call cap" do
    bare = [%{id: "01_bare", name: "bare", path: "e2e/01_bare.exs", cap: nil}]

    assert {:error, msg} = Runner.preflight("sk-x", bare, fn -> :ok end)
    assert msg =~ "01_bare"
    assert msg =~ "cap"
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

    assert %{status: :fail, calls: nil, reason: "timeout: killed after 1500 ms"} = result

    assert {_, status} =
             System.cmd("kill", ["-0", Integer.to_string(result.os_pid)], stderr_to_stdout: true)

    assert status != 0, "os pid #{result.os_pid} is still alive"
  end

  @tag :tmp_dir
  test "run_one fails a scenario whose E2E_RESULT line is malformed", %{tmp_dir: dir} do
    result =
      Runner.run_one(%{id: "x", name: "x", path: "x"},
        report_dir: dir,
        timeout_ms: 30_000,
        command: {"elixir", ["-e", ~S|IO.puts("E2E_RESULT {oops")|]},
        echo: false
      )

    assert %{status: :fail, exit: 0, calls: nil} = result
    assert result.reason =~ "malformed E2E_RESULT"
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
