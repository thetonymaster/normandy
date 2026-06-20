# verify/support.exs — shared helpers for verify/*.exs live smokes.
# Run scripts under MIX_ENV=test so stub mode + protocol consolidation-off are available.
defmodule Smoke.Support do
  @live_cap 15
  @model "claude-haiku-4-5-20251001"

  def start do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: __MODULE__)
    :ok
  end

  def model, do: @model

  @doc """
  Stub client when NORMANDY_SMOKE_STUB=true (free), else the live Claudio adapter.
  `extra_options` is merged into the live client's options (ignored for the stub),
  e.g. `client(%{structured_outputs: false})` to force the legacy path.
  """
  def client(extra_options \\ %{}) do
    if System.get_env("NORMANDY_SMOKE_STUB") == "true" do
      %NormandyTest.Support.ModelMockup{}
    else
      %Normandy.LLM.ClaudioAdapter{
        api_key: System.fetch_env!("API_KEY"),
        options: Map.merge(%{timeout: 60_000, max_retries: 1}, extra_options)
      }
    end
  end

  @doc "True for a real (paid) run, false under NORMANDY_SMOKE_STUB=true."
  def live?, do: System.get_env("NORMANDY_SMOKE_STUB") != "true"

  @doc "Count a live call and abort the run if the hard cap is exceeded."
  def record_call! do
    if System.get_env("NORMANDY_SMOKE_STUB") == "true" do
      :ok
    else
      n = Agent.get_and_update(__MODULE__, fn n -> {n + 1, n + 1} end)

      if n > @live_cap do
        IO.puts("INVARIANT FAILED: live-call cap #{@live_cap} exceeded (#{n})")
        System.halt(2)
      end

      :ok
    end
  end

  @doc "Hard invariant: print and exit non-zero on break so a re-run catches regressions."
  def assert!(label, cond, msg) do
    if cond do
      IO.puts("  ok: #{label}")
    else
      IO.puts("INVARIANT FAILED: #{label} — #{msg}")
      System.halt(2)
    end
  end

  def report do
    n =
      if System.get_env("NORMANDY_SMOKE_STUB") == "true", do: 0, else: Agent.get(__MODULE__, & &1)

    IO.puts("\nLIVE CALLS USED: #{n}")
  end
end
