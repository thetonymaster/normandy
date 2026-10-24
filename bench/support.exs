defmodule Bench.Support do
  # Shared by every bench/*.exs script (bench/README.md): Benchee options from the
  # BENCH_* env vars, the banner each script prints, and the path assertion it makes
  # before measuring.

  @results_dir "bench/results"
  @tag_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc "Benchee options for `script` (its bare name, e.g. \"type_dump\"); `extra` wins."
  @spec run_opts(String.t(), keyword()) :: keyword()
  def run_opts(script, extra \\ []) do
    save = tag("BENCH_SAVE")
    compare = tag("BENCH_COMPARE")

    if save && save == compare do
      raise ArgumentError, "BENCH_SAVE and BENCH_COMPARE are both #{save}; save under a new tag"
    end

    times()
    |> Keyword.merge(save_opts(script, save))
    |> Keyword.merge(load_opts(script, compare))
    |> Keyword.merge(extra)
  end

  @doc "Prints what the script measures, its input sizes and the shape to expect."
  @spec banner(String.t(), [String.t()], String.t()) :: :ok
  def banner(title, sizes, expected) do
    IO.puts("""

    ## #{title}
    inputs:   #{Enum.join(sizes, ", ")}
    expected: #{expected}
    """)
  end

  @doc "Raises `message` unless `condition`: the input must reach the measured path."
  @spec assert!(boolean(), String.t()) :: :ok
  def assert!(true, _message), do: :ok
  def assert!(false, message), do: raise("bench assertion failed: " <> message)

  defp times do
    if System.get_env("BENCH_QUICK") == "1",
      do: [warmup: 0.2, time: 1, memory_time: 0.2],
      else: [warmup: 1, time: 5, memory_time: 1]
  end

  defp save_opts(_script, nil), do: []

  defp save_opts(script, tag) do
    File.mkdir_p!(@results_dir)
    [save: [path: result_path(script, tag), tag: tag]]
  end

  defp load_opts(_script, nil), do: []

  defp load_opts(script, tag) do
    path = result_path(script, tag)

    unless File.regular?(path) do
      raise ArgumentError,
            "BENCH_COMPARE=#{tag}: no saved run at #{path}; " <>
              "run BENCH_SAVE=#{tag} mix bench bench/#{script}.exs first"
    end

    [load: path]
  end

  defp result_path(script, tag), do: Path.join(@results_dir, "#{script}-#{tag}.benchee")

  # nil when unset; an empty or path-like tag raises (it becomes part of a file name).
  defp tag(var) do
    case System.fetch_env(var) do
      :error ->
        nil

      {:ok, tag} ->
        if Regex.match?(@tag_format, tag) and not String.contains?(tag, "..") do
          tag
        else
          raise ArgumentError,
                "#{var}=#{inspect(tag)}: tags may only use letters, digits, . _ - " <>
                  "(and start with a letter or digit)"
        end
    end
  end
end
