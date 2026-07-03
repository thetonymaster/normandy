defmodule AutoresumeDemo.EnvCredentialProvider do
  @moduledoc """
  Node-local credential provider. Reads ANTHROPIC_API_KEY from the environment.
  In DEMO_MODE=simulated, returns a placeholder so Tier-2 reconstruction (which
  is fail-closed on a missing token) still proceeds — the SimClient ignores it.
  """
  @behaviour Normandy.Behaviours.CredentialProvider

  @impl true
  def get_token(_provider, _opts) do
    case {Application.get_env(:autoresume_demo, :demo_mode, :real),
          System.get_env("ANTHROPIC_API_KEY")} do
      {_mode, key} when is_binary(key) and key != "" -> {:ok, key}
      {:simulated, _} -> {:ok, "SIMULATED-NO-KEY"}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end
end
