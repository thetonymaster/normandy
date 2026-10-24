defmodule Normandy.Tools.Memory.RenderTest do
  use ExUnit.Case, async: true
  alias Normandy.Tools.Memory.Render

  test "directory/2: header, root line, two levels, hidden and node_modules excluded" do
    docs = [
      %{path: "/memories/a.md", size: 1536},
      %{path: "/memories/notes/q4.md", size: 100},
      %{path: "/memories/notes/deep/x.md", size: 50},
      %{path: "/memories/.secret", size: 9},
      %{path: "/memories/node_modules/y", size: 9}
    ]

    assert Render.directory("/memories", docs) ==
             """
             Here're the files and directories up to 2 levels deep in /memories, excluding hidden items and node_modules:
             1.6K\t/memories
             1.5K\t/memories/a.md
             150B\t/memories/notes
             50B\t/memories/notes/deep
             100B\t/memories/notes/q4.md\
             """
  end

  test "directory/2 on an empty root is the header and the root line" do
    assert Render.directory("/memories", []) ==
             "Here're the files and directories up to 2 levels deep in /memories, excluding hidden items and node_modules:\n0B\t/memories"
  end

  test "file/4 numbers lines six wide with a tab" do
    assert {:ok,
            "Here's the content of /memories/n.txt with line numbers:\n     1\tHello\n     2\tWorld"} =
             Render.file("/memories/n.txt", "Hello\nWorld\n", nil, 16_000)
  end

  test "file/4 view_range slices, -1 reads to the end, a bad range is an error" do
    text = "a\nb\nc\nd"
    assert {:ok, out} = Render.file("/memories/n", text, [2, 3], 16_000)
    assert out =~ "     2\tb\n     3\tc"
    refute out =~ "\td"
    assert {:ok, out} = Render.file("/memories/n", text, [3, -1], 16_000)
    assert out =~ "     3\tc\n     4\td"

    assert {:error, :invalid_line,
            "Error: Invalid `view_range` parameter: [3, 9]. It should be within the range of lines of the file: [1, 4]"} =
             Render.file("/memories/n", text, [3, 9], 16_000)
  end

  test "file/4 cuts at max_chars and says where to continue" do
    text = Enum.map_join(1..100, "\n", &"line #{&1}")
    assert {:ok, out} = Render.file("/memories/n", text, nil, 200)
    assert out =~ "[truncated at line"
    assert out =~ "use view_range ["
  end

  test "snippet/3 shows the edited lines with four lines of context" do
    text = Enum.map_join(1..20, "\n", &"l#{&1}")
    out = Render.snippet(text, 10, 10)
    assert out =~ "     6\tl6"
    assert out =~ "    14\tl14"
    refute out =~ "\tl5\n"
  end

  test "human/1" do
    assert Render.human(512) == "512B"
    assert Render.human(1536) == "1.5K"
    assert Render.human(1_258_291) == "1.2M"
  end
end
