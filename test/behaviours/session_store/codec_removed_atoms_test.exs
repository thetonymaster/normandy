defmodule Normandy.Behaviours.SessionStore.CodecRemovedAtomsTest do
  # Stored data that names an atom 2.0 no longer uses still decodes with
  # `binary_to_term(_, [:safe])` (Postgres, Redis), in a VM without Ecto: a Redis-only
  # deployment has no Ecto, so an atom only Ecto (or Normandy's Ecto-backed modules)
  # names does not exist there.
  use ExUnit.Case, async: true

  @fixture Path.expand("../../fixtures/templates/v1_0_0_session_template.etf", __DIR__)

  # The 1.0 fixture with 1.0's alias strategy :sliding_window (removed in 2.0), stored as
  # Postgres and Redis store it.
  defp sliding_window_template_binary do
    tmpl = @fixture |> File.read!() |> :erlang.binary_to_term()

    tmpl
    |> put_in(
      [:behaviours_refs, :compactor],
      {Normandy.Behaviours.Compactor.WindowManager,
       [max_tokens: 200_000, strategy: :sliding_window]}
    )
    |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})
    |> :erlang.term_to_binary()
  end

  # A struct as a build with `__meta__` stored it: `Normandy.Metadata`, state :built.
  defp legacy_struct_binary do
    :erlang.term_to_binary(%{
      __struct__: Normandy.Agents.BaseAgentOutputSchema,
      chat_message: "x",
      __meta__: %{
        __struct__: Normandy.Metadata,
        state: :built,
        source: nil,
        context: nil,
        schema: Normandy.Agents.BaseAgentOutputSchema
      }
    })
  end

  # Normandy's ebin without its Ecto-backed modules (compiled only when Ecto is present),
  # and every other code path entry but Ecto's, Ecto SQL's and Postgrex's.
  defp code_path_without_ecto(tmp) do
    normandy_ebin = :normandy |> :code.lib_dir() |> Path.join("ebin")
    ebin = Path.join(tmp, "ebin")
    File.mkdir_p!(ebin)

    for file <- File.ls!(normandy_ebin), not String.contains?(file, "Postgres") do
      File.cp!(Path.join(normandy_ebin, file), Path.join(ebin, file))
    end

    excluded = Enum.map([:ecto, :ecto_sql, :postgrex], &to_string(:code.lib_dir(&1)))

    paths =
      :code.get_path()
      |> Enum.map(&to_string/1)
      |> Enum.reject(fn path ->
        Path.expand(path) == Path.expand(normandy_ebin) or
          Enum.any?(excluded, &String.starts_with?(path, &1))
      end)

    [ebin | paths]
  end

  @tag :tmp_dir
  test "a :sliding_window template and a legacy __meta__ struct decode without Ecto", %{
    tmp_dir: tmp
  } do
    script = """
    alias Normandy.Behaviours.SessionStore.Codec
    nil = Code.ensure_loaded?(Ecto) || nil

    tmpl = #{inspect(Base.encode64(sliding_window_template_binary()))} |> Base.decode64!() |> Codec.decode()

    supplement = %{
      toolset: nil,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> %Normandy.Test.StubClient{} end
    }

    config = Normandy.Agents.ConfigTemplate.rebuild(tmpl, supplement, "token")

    struct = #{inspect(Base.encode64(legacy_struct_binary()))} |> Base.decode64!() |> Codec.decode()

    IO.puts(
      inspect([
        config.behaviours.compactor,
        Map.has_key?(struct, :__meta__),
        struct.chat_message
      ])
    )
    """

    args = Enum.flat_map(code_path_without_ecto(tmp), &["-pa", &1])
    elixir = Path.expand("../../bin/elixir", Application.app_dir(:elixir))
    elixir = if File.exists?(elixir), do: elixir, else: System.find_executable("elixir")
    {out, status} = System.cmd(elixir, args ++ ["-e", script], stderr_to_stdout: true)

    assert status == 0, out

    assert String.trim(out) =~
             ~s([{Normandy.Behaviours.Compactor.WindowManager, [strategy: :oldest_first, context_window: 200000]}, false, "x"])
  end
end
