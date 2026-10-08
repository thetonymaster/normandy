defmodule Normandy.Release.ReleaseVersionScriptTest do
  @moduledoc """
  Task 7.4a (decision 27 F1): `.github/scripts/release-version.sh` decides whether the
  Release workflow publishes. A version on the last line of `cog bump --auto --dry-run`
  releases it; cog's "nothing to bump" output does not; a cog failure fails the step. A
  stub `cog` on `PATH` plays cog.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @script Path.expand("../../.github/scripts/release-version.sh", __DIR__)

  # cog 7.0.0's stdout with nothing to release (observed on a clone tagged v2.0.0).
  @no_bump """
  No conventional commits for your repository that required a bump. Changelogs, version and hooks are not touched.
  Pre-Hooks and Post-Hooks have been skipped.\
  """

  defp run(dir, cog_stdout, cog_exit) do
    stub = Path.join(dir, "cog")
    File.write!(stub, ~s(#!/bin/sh\nprintf '%s\\n' "$COG_STUB_OUT"\nexit "$COG_STUB_EXIT"\n))
    File.chmod!(stub, 0o755)

    {out, status} =
      System.cmd("bash", [@script],
        env: [
          {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
          {"COG_STUB_OUT", cog_stdout},
          {"COG_STUB_EXIT", Integer.to_string(cog_exit)}
        ],
        stderr_to_stdout: true
      )

    {String.split(out, "\n", trim: true), status}
  end

  test "a version on the dry run's last line releases it", %{tmp_dir: dir} do
    {lines, status} = run(dir, "Bumped version: v1.3.0 -> v2.0.0\nv2.0.0", 0)

    assert status == 0
    assert "release=true" in lines
    assert "version=v2.0.0" in lines
  end

  test "cog's nothing-to-bump output, exit 0, does not release", %{tmp_dir: dir} do
    {lines, status} = run(dir, @no_bump, 0)

    assert status == 0
    assert "release=false" in lines
    refute "release=true" in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "version="))
  end

  test "a cog failure fails the step instead of skipping the release", %{tmp_dir: dir} do
    {lines, status} = run(dir, "Error: invalid cog.toml", 3)

    assert status == 1
    assert "cog bump --auto --dry-run failed; see its output above." in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "release="))
  end
end
