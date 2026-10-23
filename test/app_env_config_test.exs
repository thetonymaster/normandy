defmodule Normandy.AppEnvConfigTest do
  @moduledoc """
  The `:normandy` application env settings that act as fallbacks when a
  per-client or per-store option is absent.
  """
  # async: false — Application.put_env is VM-global.
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.{AgentMemory, BaseIOSchema, StreamProcessor}
  alias Normandy.LLM.{ClaudioAdapter, StructuredOutputs}
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.Test.StubClient

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

  describe ":adapter" do
    # Normandy.JSON calls an adapter's encode!/2 and decode/1, nothing else.
    defmodule TaggingJson do
      @moduledoc false
      def encode!(_value, []), do: "tagged"
      def encode!(_value, pretty: true), do: "tagged-pretty"
    end

    test "is read when an io_schema struct is encoded, not when it was compiled" do
      put_env(:adapter, TaggingJson)
      value = %MultiField{}

      assert BaseIOSchema.to_json(value) == "tagged"
    end

    defmodule TaggingDecoder do
      @moduledoc false
      def decode(_json), do: {:ok, %{"decoded_by" => "adapter", "chat_message" => "via adapter"}}
      def encode!(_value, _opts), do: "schema-by-adapter"
    end

    test "decodes model output and tool input, and encodes the schema prompt" do
      put_env(:adapter, TaggingDecoder)

      assert %{"decoded_by" => "adapter"} =
               Dispatch.normalize_tool_input(~s({"a": 1}))

      assert AgentMemory.unwrap_llm_content(~s({"chat_message": "x"})) ==
               "via adapter"

      events = [
        %{
          type: "content_block_start",
          index: 0,
          content_block: %{"type" => "tool_use", "id" => "t", "name" => "n", "input" => %{}}
        },
        %{
          type: "content_block_delta",
          index: 0,
          delta: %{"type" => "input_json_delta", "partial_json" => ~s({"a": 1})}
        },
        %{type: "content_block_stop", index: 0}
      ]

      assert [%{"input" => %{"decoded_by" => "adapter"}}] =
               StreamProcessor.build_final_message(events).content

      agent =
        BaseAgent.init(%{
          client: %StubClient{
            notify: self(),
            reply: &Map.put(&1, :chat_message, "hi")
          },
          model: "m"
        })

      BaseAgent.run!(agent, "hello")
      assert_received {:converse, %Normandy.LLM.Request{system: system}, _opts}
      assert system =~ "schema-by-adapter"
    end

    test "decode!/1 and AgentMemory.load/1 need only the adapter's decode/1" do
      put_env(:adapter, TaggingDecoder)

      assert %{"decoded_by" => "adapter"} = Normandy.JSON.decode!("{}")

      assert_raise ArgumentError, ~r/unsupported dump version nil/, fn ->
        AgentMemory.load("{}")
      end
    end

    defmodule BareReasonDecoder do
      @moduledoc false
      def decode(_json), do: {:error, :invalid}
      def encode!(_value, _opts), do: "{}"
    end

    test "a decode/1 that returns a bare reason is an ArgumentError naming the adapter" do
      put_env(:adapter, BareReasonDecoder)

      assert_raise ArgumentError,
                   "Normandy.AppEnvConfigTest.BareReasonDecoder.decode/1 must return " <>
                     "{:ok, term} or {:error, exception}, got: {:error, a reason that is not an exception}",
                   fn -> Normandy.JSON.decode("{}") end
    end

    test "an adapter that is not a module is an ArgumentError" do
      put_env(:adapter, "Jason")

      assert_raise ArgumentError,
                   "config :normandy, :adapter must be a module with encode!/2 and decode/1, " <>
                     "got: a string (5 bytes)",
                   fn -> Normandy.JSON.encode!(%{}) end
    end
  end

  describe ":redis_wait" do
    @describetag :redis

    test "applies to a store handle without its own wait" do
      put_env(:redis_wait, {1, 50})
      store = Redis.new()

      # The test Redis has no replicas, so a wait for one is never met.
      assert {:error, {:wait_unmet, 0, 1}} =
               Redis.save_turn_state(store, "s1", :state, false)
    end
  end
end
