defmodule AutoresumeDemo.EnvCredentialProviderTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.EnvCredentialProvider, as: P

  setup do
    prev_key = System.get_env("ANTHROPIC_API_KEY")
    prev_mode = Application.get_env(:autoresume_demo, :demo_mode)

    on_exit(fn ->
      if prev_key,
        do: System.put_env("ANTHROPIC_API_KEY", prev_key),
        else: System.delete_env("ANTHROPIC_API_KEY")

      Application.put_env(:autoresume_demo, :demo_mode, prev_mode)
    end)

    :ok
  end

  test "returns the env key when present" do
    System.put_env("ANTHROPIC_API_KEY", "sk-test-123")
    assert {:ok, "sk-test-123"} = P.get_token(%{}, [])
  end

  test "returns a placeholder token in simulated mode when no key" do
    System.delete_env("ANTHROPIC_API_KEY")
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    assert {:ok, "SIMULATED-NO-KEY"} = P.get_token(%{}, [])
  end

  test "errors in real mode when no key" do
    System.delete_env("ANTHROPIC_API_KEY")
    Application.put_env(:autoresume_demo, :demo_mode, :real)
    assert {:error, :missing_anthropic_api_key} = P.get_token(%{}, [])
  end
end
