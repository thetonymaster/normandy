defmodule AgentHorde.CLI do
  @moduledoc """
  Interactive terminal entry point for AgentHorde.

  Run `AgentHorde.CLI.start/0` to enter a REPL loop: type a research question,
  watch the 7-stage pipeline progress, and receive a written report.

  Type `/quit` or send EOF to exit.
  """

  alias AgentHorde.Pipeline

  @banner """
  ╔══════════════════════════════════════════════════════════╗
  ║              🐝  Agent Horde Research CLI  🐝              ║
  ║       Multi-LLM · 7-stage · Parallel fan-out             ║
  ╚══════════════════════════════════════════════════════════╝
  """

  @doc "Start the interactive CLI loop."
  def start do
    IO.puts(@banner)
    loop()
  end

  # ---------------------------------------------------------------------------
  # Private — loop
  # ---------------------------------------------------------------------------

  defp loop do
    case IO.gets("🧠 Ask the horde: ") do
      :eof ->
        IO.puts("\nBye!")

      {:error, _reason} ->
        IO.puts("\nBye!")

      input when is_binary(input) ->
        question = String.trim(input)

        if question == "/quit" do
          IO.puts("Bye!")
        else
          run_pipeline(question)
          loop()
        end
    end
  end

  defp run_pipeline(""), do: :ok

  defp run_pipeline(question) do
    t0 = System.monotonic_time(:millisecond)

    stage_ref = :ets.new(:cli_stage_times, [:set, :private])
    :ets.insert(stage_ref, {:t0, t0})

    on_event = fn event ->
      now = System.monotonic_time(:millisecond)
      [{:t0, start}] = :ets.lookup(stage_ref, :t0)
      elapsed = now - start
      :ets.insert(stage_ref, {:t0, now})
      IO.puts(format_event(event, elapsed))
    end

    {:ok, %{path: path, report: report}} = Pipeline.run(question, on_event: on_event)
    IO.puts("\n" <> String.duplicate("─", 60))
    IO.puts(report)
    IO.puts(String.duplicate("─", 60))
    IO.puts("📄 Saved to: #{path}\n")

    :ets.delete(stage_ref)
  end

  # ---------------------------------------------------------------------------
  # Public pure formatters (tested)
  # ---------------------------------------------------------------------------

  @doc """
  Format a pipeline stage event into a human-readable log line.

  `format_event({stage_atom, payload})` returns a string that is safe to
  `IO.puts/1`. No side-effects.
  """
  @spec format_event({atom(), map()}) :: String.t()
  def format_event(event), do: format_event(event, nil)

  @doc false
  @spec format_event({atom(), map()}, non_neg_integer() | nil) :: String.t()
  def format_event({:plan, %{queries: queries}}, elapsed) do
    "▸ ① Planner → #{length(queries)} queries#{elapsed_suffix(elapsed)}"
  end

  def format_event({:search, %{count: count}}, elapsed) do
    "▸ ② Searching: Exa · SerpAPI · Serper (parallel) → #{count} sources#{elapsed_suffix(elapsed)}"
  end

  def format_event({:curate, %{urls: urls}}, elapsed) do
    "▸ ③ Curator → #{length(urls)} sources selected#{elapsed_suffix(elapsed)}"
  end

  def format_event({:scrape, %{count: count}}, elapsed) do
    "▸ ④ Scraping #{count} pages with Firecrawl (parallel)#{elapsed_suffix(elapsed)}"
  end

  def format_event({:analyze, %{count: count}}, elapsed) do
    "▸ ⑤ Analyzing on Claude · GPT-4o · Llama [DO] (parallel) → #{count} analyses#{elapsed_suffix(elapsed)}"
  end

  def format_event({:edit, %{length: bytes}}, elapsed) do
    "▸ ⑥ Editor → synthesizing report (#{bytes} bytes)#{elapsed_suffix(elapsed)}"
  end

  def format_event({:write, %{path: path}}, elapsed) do
    "▸ ⑦ Wrote report → #{path}#{elapsed_suffix(elapsed)}"
  end

  def format_event({stage, payload}, _elapsed) do
    "▸ #{stage}: #{inspect(payload)}"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp elapsed_suffix(nil), do: ""
  defp elapsed_suffix(ms), do: " [#{ms}ms]"
end
