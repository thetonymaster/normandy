defmodule Normandy.Behaviours.CredentialProviderTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.CredentialProvider
  alias Normandy.LLM.ClaudioAdapter

  describe "FromClient" do
    test "extracts a binary api_key from a client struct" do
      client = %ClaudioAdapter{api_key: "sk-test-123"}
      assert CredentialProvider.FromClient.get_token(client, []) == {:ok, "sk-test-123"}
    end

    test "extracts api_key from any map exposing the field (no hard ClaudioAdapter dep)" do
      assert CredentialProvider.FromClient.get_token(%{api_key: "sk-abc"}, []) == {:ok, "sk-abc"}
    end

    test "returns {:error, :no_api_key} when absent or non-binary" do
      assert CredentialProvider.FromClient.get_token(%{}, []) == {:error, :no_api_key}
      assert CredentialProvider.FromClient.get_token(%{api_key: nil}, []) == {:error, :no_api_key}
    end

    test "implements the CredentialProvider behaviour" do
      behaviours = CredentialProvider.FromClient.module_info(:attributes)[:behaviour] || []
      assert CredentialProvider in behaviours
    end
  end
end
