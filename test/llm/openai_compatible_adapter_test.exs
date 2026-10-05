defmodule Normandy.LLM.OpenAICompatibleAdapterTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.OpenAICompatibleAdapter, as: Adapter
  alias Normandy.LLM.{Request, Response}

  # Routes the client's HTTP calls to `plug` through Req.Test, under a name only
  # this test uses.
  defp stub(plug) do
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, plug)
    [plug: {Req.Test, name}]
  end

  describe "convert_messages/1" do
    test "maps Normandy messages to OpenAI role/content maps" do
      msgs = [
        %Message{role: "system", content: "You are helpful."},
        %Message{role: "user", content: "Hi"}
      ]

      assert Adapter.convert_messages(msgs) == [
               %{"role" => "system", "content" => "You are helpful."},
               %{"role" => "user", "content" => "Hi"}
             ]
    end

    test "the unsupported-content error names the content's type, not the content" do
      error =
        assert_raise ArgumentError, fn ->
          Adapter.convert_messages([
            %Message{role: "user", content: [%{"secret" => "user data"}]}
          ])
        end

      refute error.message =~ "user data"
      assert error.message =~ "a list"
    end

    test "raises on non-string content (text-only v1)" do
      assert_raise ArgumentError, ~r/text-only v1/, fn ->
        Adapter.convert_messages([%Message{role: "user", content: [%{}]}])
      end
    end
  end

  describe "extract_text/1" do
    test "pulls assistant content from a chat-completions body" do
      body = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "hello world"}}]
      }

      assert Adapter.extract_text(body) == "hello world"
    end

    test "returns empty string when no choices" do
      assert Adapter.extract_text(%{"choices" => []}) == ""
    end
  end

  describe "converse/3 (stubbed transport)" do
    test "returns response_model with prose in :chat_message" do
      req_options =
        stub(fn conn ->
          Req.Test.json(conn, %{
            "id" => "chatcmpl-42",
            "choices" => [
              %{"message" => %{"content" => "The answer is 42."}, "finish_reason" => "stop"}
            ],
            "usage" => %{"total_tokens" => 10}
          })
        end)

      client = %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: %{req_options: req_options}
      }

      # Default agent output schema — confirmed: Normandy.Agents.BaseAgentOutputSchema
      schema = %Normandy.Agents.BaseAgentOutputSchema{}
      msgs = [%Message{role: "user", content: "What is the answer?"}]

      request = %Request{
        model: "gpt-4o",
        temperature: 0.7,
        max_tokens: 1024,
        messages: msgs,
        response_model: schema
      }

      {:ok, %Response{content: resp, usage: usage, meta: meta, stop_reason: stop_reason}} =
        Model.converse(client, request, [])

      assert resp.chat_message == "The answer is 42."
      assert usage == %{"total_tokens" => 10}
      assert meta == %{response_id: "chatcmpl-42", finish_reason: "stop"}
      assert stop_reason == :end_turn
    end

    test "finish_reason length is stop_reason :max_tokens" do
      req_options =
        stub(fn conn ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "cut"}, "finish_reason" => "length"}]
          })
        end)

      client = %Adapter{api_key: "k", options: %{req_options: req_options}}

      assert {:ok, %Response{stop_reason: :max_tokens, content: "cut"}} =
               Model.converse(client, %Request{model: "m", max_tokens: 8, messages: []}, [])
    end

    test "an unknown finish_reason is a nil stop_reason; the string stays in meta" do
      req_options =
        stub(fn conn ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "x"}, "finish_reason" => "vendor_thing"}]
          })
        end)

      client = %Adapter{api_key: "k", options: %{req_options: req_options}}

      assert {:ok, %Response{stop_reason: nil, meta: %{finish_reason: "vendor_thing"}}} =
               Model.converse(client, %Request{model: "m", max_tokens: 8, messages: []}, [])
    end

    test "the system prompt is sent as the first message" do
      test_pid = self()

      req_options =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:openai_body, Jason.decode!(body)})
          Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
        end)

      client = %Adapter{api_key: "k", options: %{req_options: req_options}}

      request = %Request{
        model: "m",
        system: "Be brief.",
        max_tokens: 8,
        messages: [%Message{role: "user", content: "hi"}]
      }

      Model.converse(client, request, [])

      assert_received {:openai_body, body}

      assert body["messages"] == [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "tools raise (text-only v1)" do
      client = %Adapter{api_key: "k"}

      request = %Request{
        model: "m",
        max_tokens: 8,
        messages: [],
        tools: [%{name: "t", description: "d", input_schema: %{}}]
      }

      assert_raise ArgumentError, ~r/does not support tools.*1 tool schema/, fn ->
        Model.converse(client, request, [])
      end
    end
  end

  describe "stream/3" do
    test "is :unsupported" do
      assert {:error, %Normandy.LLMError{type: :unsupported, retryable?: false}} =
               Model.stream(
                 %Adapter{api_key: "k"},
                 %Request{model: "m", max_tokens: 8, messages: []},
                 []
               )
    end
  end

  describe ":max_tokens_param" do
    # The decoded JSON body of one converse/3 call with `max_tokens` against a client
    # whose options are `options` plus a body-capturing stub.
    defp capture_request_body(options, max_tokens: max_tokens) do
      test_pid = self()

      req_options =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:openai_body, Jason.decode!(body)})
          Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
        end)

      client = %Adapter{api_key: "k", options: Map.put(options, :req_options, req_options)}

      request = %Request{
        model: "m",
        max_tokens: max_tokens,
        messages: [%Message{role: "user", content: "hi"}],
        response_model: nil
      }

      {:ok, %Response{}} = Model.converse(client, request, [])
      assert_received {:openai_body, body}
      body
    end

    for {param, key} <- [max_tokens: "max_tokens", max_completion_tokens: "max_completion_tokens"] do
      test "#{param} sends max_tokens as #{key}" do
        body = capture_request_body(%{max_tokens_param: unquote(param)}, max_tokens: 2048)
        assert body[unquote(key)] == 2048
        other = if unquote(key) == "max_tokens", do: "max_completion_tokens", else: "max_tokens"
        refute Map.has_key?(body, other)
      end
    end

    test "the default is max_tokens" do
      assert capture_request_body(%{}, max_tokens: 2048)["max_tokens"] == 2048
    end

    test ":omit sends neither key" do
      body = capture_request_body(%{max_tokens_param: :omit}, max_tokens: 2048)
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
    end

    test "an unknown value raises at init naming the allowed ones" do
      client = %Adapter{
        api_key: "k",
        options: %{max_tokens_param: "max_tokens"}
      }

      assert_raise ArgumentError,
                   ~r/:max_tokens_param must be :max_tokens, :max_completion_tokens or :omit, got: "max_tokens"/,
                   fn -> BaseAgent.init(%{client: client, model: "m"}) end
    end
  end

  describe "converse/3 when the output does not parse" do
    defmodule Answer do
      use Normandy.Schema

      io_schema "an answer" do
        field(:answer, :string, description: "the answer", required: true)
      end
    end

    defp prose_client(options) do
      req_options =
        stub(fn conn ->
          Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "just prose"}}]})
        end)

      %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: Map.put(options, :req_options, req_options)
      }
    end

    defp converse_prose(options, schema) do
      Model.converse(
        prose_client(options),
        %Request{model: "gpt-4o", max_tokens: 1024, messages: [], response_model: schema},
        []
      )
    end

    test "on_parse_failure: :error returns an :invalid_output error" do
      assert {:error, %Normandy.LLMError{type: :invalid_output}} =
               converse_prose(
                 %{on_parse_failure: :error},
                 %Normandy.Agents.BaseAgentOutputSchema{}
               )
    end

    test "the failed call's usage rides on the :invalid_output error" do
      req_options =
        stub(fn conn ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "just prose"}}],
            "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 4}
          })
        end)

      client = %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: %{on_parse_failure: :error, req_options: req_options}
      }

      assert {:error, %Normandy.LLMError{type: :invalid_output} = error} =
               Model.converse(
                 client,
                 %Normandy.LLM.Request{
                   model: "gpt-4o",
                   max_tokens: 1024,
                   messages: [],
                   response_model: %Normandy.Agents.BaseAgentOutputSchema{}
                 },
                 []
               )

      assert error.usage == %{"prompt_tokens" => 9, "completion_tokens" => 4}
      assert error.usage_counts == %{input_tokens: 9, output_tokens: 4}
    end

    test "a schema without :chat_message has nothing to fall back to: :invalid_output" do
      assert {:error, %Normandy.LLMError{type: :invalid_output}} = converse_prose(%{}, %Answer{})
    end
  end

  describe "build_body/4 with unset sampling parameters" do
    alias Normandy.LLM.OpenAICompatibleAdapter, as: A

    test "nil temperature and max_tokens are left out (not sent as JSON null)" do
      body =
        A.build_body("m", nil, nil, [%Normandy.Components.Message{role: "user", content: "hi"}])

      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "max_tokens")
    end

    test "set values are sent" do
      body =
        A.build_body("m", 0.2, 64, [%Normandy.Components.Message{role: "user", content: "hi"}])

      assert body["temperature"] == 0.2
      assert body["max_tokens"] == 64
    end

    test "an agent built without temperature sends none on the wire (BaseAgent.run → converse)" do
      test_pid = self()

      req_options =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:openai_body, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "ok"}}],
            "usage" => %{"total_tokens" => 1}
          })
        end)

      client = %A{
        api_key: "k",
        base_url: "https://example.test/v1",
        options: %{req_options: req_options}
      }

      agent = BaseAgent.init(%{client: client, model: "gpt-4o"})
      BaseAgent.run!(agent, "hi")

      assert_received {:openai_body, body}
      refute Map.has_key?(body, "temperature")
    end
  end

  describe "converse/3 failures" do
    @key "sk-openai-test-canary"

    defp failing_client(plug) do
      %Adapter{
        api_key: @key,
        base_url: "https://example.test/v1",
        options: %{req_options: [retry: false] ++ stub(plug)}
      }
    end

    defp call(client) do
      Model.converse(
        client,
        %Normandy.LLM.Request{
          model: "gpt-4o",
          max_tokens: 1024,
          messages: [%Message{role: "user", content: "hi"}],
          response_model: %Normandy.Agents.BaseAgentOutputSchema{}
        },
        []
      )
    end

    for {status, type, retryable?} <- [
          {401, :authentication, false},
          {403, :permission, false},
          {404, :not_found, false},
          {422, :invalid_request, false},
          {429, :rate_limit, true},
          {408, :server, true},
          {500, :server, true},
          {503, :server, true}
        ] do
      test "HTTP #{status} -> #{type}, retryable?: #{retryable?}" do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_status(unquote(status))
          |> Req.Test.json(%{"error" => %{"message" => "provider says no"}})
        end

        assert {:error, %Normandy.LLMError{} = e} = call(failing_client(plug))
        assert e.type == unquote(type)
        assert e.status == unquote(status)
        assert e.retryable? == unquote(retryable?)
        assert e.message =~ "provider says no"
        refute inspect(e) =~ @key
      end
    end

    test "a body without an error message falls back to HTTP <status>" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 502, "") end

      assert {:error, %Normandy.LLMError{message: "LLM call failed: server (502): HTTP 502"}} =
               call(failing_client(plug))
    end

    test "a transport error -> :transport, retryable" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, %Normandy.LLMError{type: :transport, retryable?: true, status: nil}} =
               call(failing_client(plug))
    end
  end
end
