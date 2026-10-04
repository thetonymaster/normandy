defmodule Normandy.Tools.Memory.PathsTest do
  use ExUnit.Case, async: true
  alias Normandy.Tools.Memory.Paths

  test "accepts the root and paths under it" do
    for p <- ["/memories", "/memories/a.md", "/memories/notes/2026/q4.md", "/memories/.hidden"] do
      assert {:ok, ^p} = Paths.validate(p)
    end
  end

  test "a trailing slash is allowed on the root only and normalises to the root" do
    assert {:ok, "/memories"} = Paths.validate("/memories/")
  end

  test "rejects every escape and malformed form before any store call" do
    for p <- [
          "/memories/../secrets.env",
          "/memories/a/../../x",
          "/memories/./a",
          "/memoriesX/a",
          "/etc/passwd",
          "memories/a",
          "/memories//a",
          "/memories/a/",
          "/memories/a\\b",
          "/memories/%2e%2e/x",
          "/memories/a\0b",
          "/memories/a\nb",
          "/memories/" <> String.duplicate("a", 250),
          <<"/memories/", 0xFF>>
        ] do
      assert {:error, :invalid_path, "Error: " <> _} = Paths.validate(p), "accepted #{inspect(p)}"
    end
  end

  test "rejects every Unicode control character (Cc), C0 and C1, without echoing the path" do
    for c <- [0x01, 0x1B, 0x7F, 0x85, 0x9F] do
      # Also outside /memories and holding `\`: the control-character check comes first,
      # so no error message carries the raw control character back to the model.
      for p <- [
            "/memories/a" <> <<c::utf8>> <> "b",
            "/etc/" <> <<c::utf8>>,
            "/memories/\\" <> <<c::utf8>>
          ] do
        assert {:error, :invalid_path, "Error: path contains a control character"} =
                 Paths.validate(p),
               "for #{inspect(p)}"
      end
    end
  end

  test "invalid UTF-8 and non-string errors name the offending path" do
    bad = <<"/memories/", 0xFF>>

    assert {:error, :invalid_path, "Error: path is not valid UTF-8 for " <> named} =
             Paths.validate(bad)

    assert named == inspect(bad)

    assert {:error, :invalid_path, "Error: path must be a string, got: nil"} =
             Paths.validate(nil)
  end

  test "resolve maps a mounted path to the mount's namespace and a store path under /memories" do
    mounts = %{"/memories/org" => {"acme/org-kb", :read_only}}

    assert %{
             namespace: "acme/org-kb",
             path: "/memories/kb.md",
             model_path: "/memories/org/kb.md",
             access: :read_only,
             mount: "/memories/org"
           } =
             Paths.resolve("/memories/org/kb.md", "acme/u-1", mounts)

    assert %{namespace: "acme/org-kb", path: "/memories", mount: "/memories/org"} =
             Paths.resolve("/memories/org", "acme/u-1", mounts)

    assert %{namespace: "acme/u-1", path: "/memories/orgs.md", access: :read_write, mount: nil} =
             Paths.resolve("/memories/orgs.md", "acme/u-1", mounts)
  end

  test "resolve picks the longest matching mount" do
    mounts = %{"/memories/org" => {"a", :read_only}, "/memories/org/team" => {"b", :read_write}}

    assert %{namespace: "b", path: "/memories/x"} =
             Paths.resolve("/memories/org/team/x", "u", mounts)
  end

  test "to_model/2 inverts the mount rewrite" do
    assert Paths.to_model("/memories/kb.md", "/memories/org") == "/memories/org/kb.md"
    assert Paths.to_model("/memories/kb.md", nil) == "/memories/kb.md"
  end
end
