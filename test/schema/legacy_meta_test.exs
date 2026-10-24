defmodule Normandy.Schema.LegacyMetaTest do
  # Data stored before schema structs dropped `__meta__` still loads and is cleaned.
  use ExUnit.Case, async: true

  alias Normandy.Schema.LegacyMeta

  @fixture Path.expand("../fixtures/templates/v1_0_0_session_template.etf", __DIR__)

  # A struct as a build with `__meta__` stored it (term_to_binary of the old struct).
  defp legacy_struct_binary do
    :erlang.term_to_binary(%{
      __struct__: Normandy.Agents.BaseAgentOutputSchema,
      chat_message: "x",
      __meta__: %{
        __struct__: Normandy.Metadata,
        state: :built,
        schema: Normandy.Agents.BaseAgentOutputSchema
      }
    })
  end

  # Decoding in a fresh VM (plain `elixir -pa`, no mix): no atom or module is loaded
  # there before the decode, so the order of the suite cannot hide a missing atom
  # (`binary_to_term(_, [:safe])`).
  test "a 1.0 template and a legacy struct decode in a fresh VM without __meta__" do
    script = """
    alias Normandy.Behaviours.SessionStore.Codec
    tmpl = #{inspect(@fixture)} |> File.read!() |> Codec.decode()
    struct = #{inspect(Base.encode64(legacy_struct_binary()))} |> Base.decode64!() |> Codec.decode()
    json = Normandy.Components.BaseIOSchema.to_json(struct)

    IO.puts(
      inspect([
        Map.has_key?(struct, :__meta__),
        Map.has_key?(tmpl.output_schema, :__meta__),
        Map.has_key?(tmpl.input_schema, :__meta__),
        String.contains?(json, "__meta__"),
        struct.chat_message
      ])
    )
    """

    args = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    {out, status} = System.cmd("elixir", args ++ ["-e", script], stderr_to_stdout: true)

    assert status == 0, out
    assert String.trim(out) =~ ~s([false, false, false, false, "x"])
  end

  describe "strip/1" do
    test "removes a legacy __meta__ at every depth and leaves foreign ones" do
      legacy = %{__struct__: Normandy.Metadata, state: :built, schema: nil}

      inner = %{
        __struct__: Normandy.Agents.BaseAgentOutputSchema,
        chat_message: "a",
        __meta__: legacy
      }

      stripped = LegacyMeta.strip(%{list: [inner], tuple: {:ok, inner}})

      assert [%{chat_message: "a"} = one] = stripped.list
      refute Map.has_key?(one, :__meta__)
      refute Map.has_key?(elem(stripped.tuple, 1), :__meta__)

      foreign = %{__struct__: Foreign, __meta__: :keep}
      assert LegacyMeta.strip(foreign) == foreign
    end
  end
end
