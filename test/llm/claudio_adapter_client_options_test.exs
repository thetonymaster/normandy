defmodule Normandy.LLM.ClaudioAdapterClientOptionsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.ClaudioAdapter

  defp client(options), do: %ClaudioAdapter{api_key: "k", options: options}

  describe "client options reach the Claudio client" do
    test ":timeout and :recv_timeout set the connect and receive timeouts" do
      req = ClaudioAdapter.to_claudio_client(client(%{timeout: 1_000, recv_timeout: 5_000}))

      assert req.options.receive_timeout == 5_000
      assert req.options.connect_options[:timeout] == 1_000
    end

    test "options[:base_url] sets the endpoint" do
      req = ClaudioAdapter.to_claudio_client(client(%{base_url: "http://localhost:4000/v1/"}))
      assert req.options.base_url == "http://localhost:4000/v1/"
    end
  end

  describe "validate_options!/1" do
    test "an unknown option raises, naming it" do
      assert_raise ArgumentError, ~r/unknown client option :thinkin/, fn ->
        ClaudioAdapter.validate_options!(client(%{thinkin: :adaptive}))
      end
    end

    test "BaseAgent.init rejects an unknown option" do
      assert_raise ArgumentError, ~r/unknown client option :enable_cacheing/, fn ->
        BaseAgent.init(%{client: client(%{enable_cacheing: true}), model: "claude-opus-5-5"})
      end
    end

    test ":enable_caching and :structured_outputs must be booleans" do
      assert_raise ArgumentError, ~r/:enable_caching must be a boolean, got: "yes"/, fn ->
        ClaudioAdapter.validate_options!(client(%{enable_caching: "yes"}))
      end

      assert_raise ArgumentError, ~r/:structured_outputs must be a boolean, got: :off/, fn ->
        ClaudioAdapter.validate_options!(client(%{structured_outputs: :off}))
      end
    end

    test "options must be a map and api_key a string" do
      assert_raise ArgumentError, ~r/options must be a map, got a list/, fn ->
        ClaudioAdapter.validate_options!(%ClaudioAdapter{api_key: "k", options: [effort: :low]})
      end

      assert_raise ArgumentError, ~r/api_key must be a non-empty string, got: nil/, fn ->
        ClaudioAdapter.validate_options!(%ClaudioAdapter{api_key: nil})
      end
    end

    test "documented options pass" do
      assert %ClaudioAdapter{} =
               ClaudioAdapter.validate_options!(
                 client(%{
                   timeout: 1_000,
                   recv_timeout: 2_000,
                   enable_caching: true,
                   structured_outputs: false,
                   effort: :low,
                   on_parse_failure: :error
                 })
               )
    end
  end
end
