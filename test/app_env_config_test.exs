defmodule Normandy.AppEnvConfigTest do
  @moduledoc """
  The `:normandy` application env settings that act as fallbacks when a
  per-client or per-store option is absent.
  """
  # async: false — Application.put_env is VM-global.
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.LLM.{ClaudioAdapter, StructuredOutputs}

  defp put_env(key, value) do
    previous = Application.fetch_env(:normandy, key)
    Application.put_env(:normandy, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:normandy, key, old)
        :error -> Application.delete_env(:normandy, key)
      end
    end)
  end

  defp client(options \\ %{}), do: %ClaudioAdapter{api_key: "k", options: options}

  describe ":structured_outputs" do
    test "false turns structured outputs off for clients that do not set it" do
      put_env(:structured_outputs, false)

      refute StructuredOutputs.enabled?(client())
      assert StructuredOutputs.enabled?(client(%{structured_outputs: true}))
    end
  end

  describe ":on_parse_failure" do
    test "sets the policy when neither the call nor the client does" do
      put_env(:on_parse_failure, :error)

      assert :error = ClaudioAdapter.__on_parse_failure_policy__(%{client: client()})

      assert :fallback =
               ClaudioAdapter.__on_parse_failure_policy__(%{
                 client: client(%{on_parse_failure: :fallback})
               })
    end
  end

  describe ":redis_wait" do
    @describetag :redis

    test "applies to a store handle without its own wait" do
      put_env(:redis_wait, {1, 50})
      store = Normandy.TestHandles.redis_session_store()

      # The test Redis has no replicas, so a wait for one is never met.
      assert {:error, {:wait_unmet, 0, 1}} =
               Redis.save_turn_state(store, "s1", :state, false)
    end
  end
end
