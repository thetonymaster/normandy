defmodule NormandyTest.LLM.ClaudioAdapterTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.Model
  alias Normandy.LLM.ClaudioAdapter

  describe "ClaudioAdapter schema" do
    test "creates adapter with required fields" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{timeout: 60_000}
      }

      assert adapter.api_key == "test-key"
      assert adapter.options.timeout == 60_000
      assert adapter.base_url == nil
    end

    test "creates adapter with custom base_url" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        base_url: "https://custom.api.com"
      }

      assert adapter.base_url == "https://custom.api.com"
    end
  end

  describe "Model protocol implementation" do
    test "implements completitions/6 (legacy compatibility)" do
      adapter = %ClaudioAdapter{api_key: "test-key"}
      response_model = %BaseAgentOutputSchema{}

      result =
        Model.completitions(
          adapter,
          "claude-3",
          0.7,
          1024,
          "test",
          response_model
        )

      # Should return the response_model unchanged for legacy API
      assert result == response_model
    end

    # Note: Testing actual converse/7 would require mocking Claudio.Client
    # and Claudio.Messages.create, which is beyond this basic test.
    # In integration tests, you would mock these dependencies.
  end

  describe "ClaudioAdapter integration" do
    test "can be used as a client in BaseAgent config" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{
          timeout: 60_000,
          enable_caching: true
        }
      }

      config = %{
        client: adapter,
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)

      assert agent.client == adapter
      assert agent.model == "claude-haiku-4-5-20251001"
      assert agent.temperature == 0.7
    end
  end

  describe "Inspect protocol" do
    test "does not leak api_key in inspect output" do
      adapter = %ClaudioAdapter{api_key: "sk-ant-secret-leak-canary"}
      output = inspect(adapter)

      refute output =~ "sk-ant-secret-leak-canary"
      refute output =~ "api_key"
    end

    test "still allows direct api_key access after redaction" do
      adapter = %ClaudioAdapter{api_key: "sk-secret"}

      assert adapter.api_key == "sk-secret"
      assert Map.get(adapter, :api_key) == "sk-secret"
      assert match?(%ClaudioAdapter{api_key: "sk-secret"}, adapter)
    end
  end

  describe "on_parse_failure policy" do
    test "defaults to :fallback" do
      assert :fallback = ClaudioAdapter.__on_parse_failure_policy__(%{})
    end

    test "honors a per-call override" do
      assert :error =
               ClaudioAdapter.__on_parse_failure_policy__(%{
                 on_parse_failure: :error
               })
    end
  end

  describe "raw completion mapping" do
    test "__raw_completion__ maps a successful Claudio response to {content, usage}" do
      response = %{content: [%{type: :text, text: "hello"}], usage: %{input_tokens: 5}}
      assert {"hello", %{input_tokens: 5}} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ joins multiple text blocks and ignores non-text blocks" do
      response = %{
        content: [%{type: :text, text: "a"}, %{type: :tool_use}, %{type: :text, text: "b"}]
      }

      assert {"a\nb", nil} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ classifies a Claudio API error as an LLMError" do
      assert {:error, %Normandy.LLMError{type: :unknown, reason: :boom}} =
               ClaudioAdapter.__raw_completion__({:error, :boom})
    end
  end

  describe "apply_parse_failure/4" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    test ":fallback policy with binary content returns schema with chat_message set" do
      result =
        ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw text", :some_reason, %{
          on_parse_failure: :fallback
        })

      assert %MultiField{chat_message: "raw text"} = result
    end

    test ":fallback policy with non-binary content returns the schema unchanged" do
      result =
        ClaudioAdapter.apply_parse_failure(%MultiField{}, nil, :some_reason, %{
          on_parse_failure: :fallback
        })

      assert %MultiField{chat_message: nil} = result
    end

    test ":error policy returns {:error, reason}" do
      assert {:error,
              %Normandy.LLMError{type: :invalid_output, retryable?: false, reason: :some_reason}} =
               ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw", :some_reason, %{
                 on_parse_failure: :error
               })
    end
  end

  describe "parse failure reporting" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    @secret "user PII in the model output"

    test "the log names the failure and the size, not the model output" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ClaudioAdapter.apply_parse_failure(
            %MultiField{},
            @secret,
            {:structured_output_unparseable, @secret},
            %{on_parse_failure: :fallback}
          )
        end)

      assert log =~ "structured_output_unparseable"
      assert log =~ "#{byte_size(@secret)} bytes"
      refute log =~ @secret
    end

    test "telemetry carries the failure tag and size, not the model output" do
      parent = self()
      id = "parse-failure-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:normandy, :json_deserializer, :fallback],
        fn _, _, meta, _ ->
          send(parent, {:fallback_meta, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        ClaudioAdapter.apply_parse_failure(
          %MultiField{},
          @secret,
          {:structured_output_unparseable, @secret},
          %{
            on_parse_failure: :fallback
          }
        )
      end)

      assert_received {:fallback_meta, meta}
      assert meta == %{reason: :structured_output_unparseable, content_bytes: byte_size(@secret)}
    end

    test "client.options[:on_parse_failure] sets the policy" do
      client = %ClaudioAdapter{api_key: "k", options: %{on_parse_failure: :error}}
      assert :error = ClaudioAdapter.__on_parse_failure_policy__(%{client: client})
    end

    test "an invalid policy raises naming the value" do
      assert_raise ArgumentError,
                   ~r/:on_parse_failure must be :fallback or :error, got: :raise/,
                   fn ->
                     ClaudioAdapter.__on_parse_failure_policy__(%{on_parse_failure: :raise})
                   end
    end
  end

  describe "structured-vs-legacy routing decision (__structured_schema_for__/3)" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp routing_client, do: %Normandy.LLM.ClaudioAdapter{api_key: "k", options: %{}}

    test "uses structured outputs for a compatible schema with no tools" do
      assert {:ok, _schema} =
               ClaudioAdapter.__structured_schema_for__(routing_client(), %MultiField{}, [])
    end

    test "skips structured outputs when tools are present (tool_use needs the legacy loop)" do
      assert :skip =
               ClaudioAdapter.__structured_schema_for__(
                 routing_client(),
                 %MultiField{},
                 tools: [%{name: "lookup"}]
               )
    end
  end

  describe "structured response interpretation" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp text_response(stop_reason, text) do
      %{stop_reason: stop_reason, content: [%{type: :text, text: text}], usage: %{}}
    end

    test "normal stop with valid JSON decodes and binds to the schema" do
      resp = text_response(:end_turn, ~s({"chat_message": "hi", "count": 2}))

      assert %MultiField{chat_message: "hi", count: 2} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "refusal routes to the parse-failure policy (default :fallback)" do
      resp = text_response(:refusal, "I can't help with that.")

      assert %MultiField{chat_message: "I can't help with that."} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "max_tokens routes to the parse-failure policy" do
      resp = text_response(:max_tokens, ~s({"chat_message": "trunca))

      assert %MultiField{chat_message: ~s({"chat_message": "trunca)} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "non-conforming content under :error policy returns an error tuple" do
      resp = text_response(:refusal, "nope")

      assert {:error,
              %Normandy.LLMError{
                type: :invalid_output,
                reason: {:structured_output_incomplete, :refusal}
              }} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
                 on_parse_failure: :error
               })
    end

    test "string-keyed stop_reason is classified like the atom-keyed form" do
      resp = %{
        "stop_reason" => "refusal",
        "content" => [%{"type" => "text", "text" => "nope"}],
        "usage" => %{}
      }

      assert {:error,
              %Normandy.LLMError{
                type: :invalid_output,
                reason: {:structured_output_incomplete, "refusal"}
              }} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
                 on_parse_failure: :error
               })
    end
  end

  describe "__structured_error_action__/1" do
    test "request-shape rejection (invalid_request_error) falls back to legacy" do
      err = %Claudio.APIError{
        type: :invalid_request_error,
        message: "schema rejected",
        status_code: 400
      }

      assert :fallback = ClaudioAdapter.__structured_error_action__(err)
    end

    test "auth/permission/rate-limit/overload/api errors propagate (no duplicate call)" do
      for type <- [
            :authentication_error,
            :permission_error,
            :rate_limit_error,
            :overloaded_error,
            :api_error,
            :not_found_error
          ] do
        err = %Claudio.APIError{type: type, message: "x", status_code: 500}
        assert :propagate = ClaudioAdapter.__structured_error_action__(err)
      end
    end

    test "transport errors (non-APIError) propagate" do
      assert :propagate = ClaudioAdapter.__structured_error_action__(:timeout)

      assert :propagate =
               ClaudioAdapter.__structured_error_action__({:transport_error, :nxdomain})
    end
  end

  describe "to_claudio_client/1" do
    test "requests go to base_url with the adapter's api key" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/models/claude-opus-5-5", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "claude-opus-5-5"}))
      end)

      client =
        ClaudioAdapter.to_claudio_client(%Normandy.LLM.ClaudioAdapter{
          api_key: "test-key",
          base_url: "http://localhost:#{bypass.port}/"
        })

      assert {:ok, %{"id" => "claude-opus-5-5"}} = Claudio.Models.get(client, "claude-opus-5-5")
    end

    test "options[:req_options] are merged into the Req request (Req.Test plug)" do
      Req.Test.stub(__MODULE__.ModelsStub, fn conn ->
        Req.Test.json(conn, %{"id" => "stubbed"})
      end)

      client =
        ClaudioAdapter.to_claudio_client(%Normandy.LLM.ClaudioAdapter{
          api_key: "test-key",
          options: %{req_options: [plug: {Req.Test, __MODULE__.ModelsStub}, retry: false]}
        })

      assert {:ok, %{"id" => "stubbed"}} = Claudio.Models.get(client, "any-model")
    end
  end

  describe "to_claudio_client/1 with invalid :req_options" do
    test "raises ArgumentError instead of silently ignoring a non-list value" do
      client = %Normandy.LLM.ClaudioAdapter{
        api_key: "test-key",
        options: %{req_options: %{plug: :oops}}
      }

      error =
        assert_raise ArgumentError, fn ->
          ClaudioAdapter.to_claudio_client(client)
        end

      assert error.message =~ ":req_options"
      assert error.message =~ "to_claudio_client/1"
      refute error.message =~ "test-key"
    end

    test "nil :req_options leaves the client unchanged" do
      client = %Normandy.LLM.ClaudioAdapter{api_key: "test-key", options: %{req_options: nil}}
      assert %Req.Request{} = ClaudioAdapter.to_claudio_client(client)
    end
  end

  describe "__apply_client_options__/3" do
    test "empty options leave the request unchanged" do
      request = Claudio.Messages.Request.new("m")
      assert ClaudioAdapter.__apply_client_options__(request, %{}) == request
    end

    test "thinking_budget still sets budget_tokens thinking" do
      request =
        ClaudioAdapter.__apply_client_options__(
          Claudio.Messages.Request.new("m"),
          %{thinking_budget: 2048}
        )

      assert request.thinking == %{"type" => "enabled", "budget_tokens" => 2048}
    end
  end

  describe "server-side fallback responses" do
    @fallback %{
      type: :fallback,
      from: %{"model" => "a"},
      to: %{"model" => "b"},
      trigger: nil,
      raw: %{}
    }

    test "content_after_last_fallback/1 without a fallback block is unchanged" do
      blocks = [%{type: :text, text: "x"}]
      assert ClaudioAdapter.content_after_last_fallback(blocks) == blocks
      assert ClaudioAdapter.content_after_last_fallback([]) == []
    end

    test "content_after_last_fallback/1 keeps only blocks after the last fallback" do
      blocks = [
        %{type: :text, text: "declined-1"},
        @fallback,
        %{type: :text, text: "declined-2"},
        %{"type" => "fallback"},
        %{type: :text, text: "served"}
      ]

      assert ClaudioAdapter.content_after_last_fallback(blocks) == [
               %{type: :text, text: "served"}
             ]
    end

    # Defensive: per the fallback doc a non-streaming response puts the fallback
    # block first and omits the declined model's output, so text *before* it
    # shouldn't occur. These pin the helper's contract anyway.
    test "extract_content/1 ignores text from the declining model" do
      response = %{
        content: [%{type: :text, text: "declined"}, @fallback, %{type: :text, text: "served"}]
      }

      assert ClaudioAdapter.extract_content(response) == "served"
    end

    test "extract_content/1 is empty when nothing follows the fallback block" do
      response = %{content: [%{type: :text, text: "I can't help with that"}, @fallback]}
      assert ClaudioAdapter.extract_content(response) == ""
    end

    test "extract_tool_uses/1 ignores tool calls from the declining model" do
      response = %{
        content: [
          %{type: :tool_use, id: "t1", name: "rm_rf", input: %{}},
          @fallback,
          %{type: :tool_use, id: "t2", name: "search", input: %{"q" => "x"}}
        ]
      }

      assert [%Normandy.Components.ToolCall{id: "t2", name: "search"}] =
               ClaudioAdapter.extract_tool_uses(response)
    end

    test "response_meta/1 names the model that served the message" do
      response = %Claudio.Messages.Response{model: "claude-opus-5-5", content: [@fallback]}
      assert ClaudioAdapter.response_meta(response) == %{served_by: "b"}

      no_fallback = %Claudio.Messages.Response{model: "claude-opus-5-5", content: []}
      assert ClaudioAdapter.response_meta(no_fallback) == %{served_by: "claude-opus-5-5"}

      assert ClaudioAdapter.response_meta(%{content: []}) == %{}

      no_model = %Claudio.Messages.Response{model: nil, content: []}
      assert ClaudioAdapter.response_meta(no_model) == %{}
    end

    test "response_meta/1 passes on the thinking blocks the API dropped or let through" do
      dropped = %{
        "type" => "thinking_dropped",
        "path" => "messages.1.content.0",
        "reason" => "prefix_binding_mismatch"
      }

      response = %Claudio.Messages.Response{content: [], input_transformations: [dropped]}
      assert ClaudioAdapter.response_meta(response) == %{input_transformations: [dropped]}

      for none <- [[], nil] do
        response = %Claudio.Messages.Response{content: [], input_transformations: none}
        assert ClaudioAdapter.response_meta(response) == %{}
      end
    end

    test "converse returns served_by from a fallback reply on the wire" do
      Req.Test.stub(__MODULE__.FallbackStub, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [
            %{
              "type" => "fallback",
              "from" => %{"model" => "claude-opus-5-5"},
              "to" => %{"model" => "claude-opus-5"}
            },
            %{"type" => "text", "text" => ~s({"chat_message": "served"})}
          ],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
        })
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options: %{
          structured_outputs: false,
          fallbacks: :default,
          req_options: [plug: {Req.Test, __MODULE__.FallbackStub}, retry: false]
        }
      }

      messages = [%Normandy.Components.Message{role: "user", content: "hi"}]

      assert {response, _usage, %{served_by: "claude-opus-5"}} =
               Model.converse(
                 client,
                 "claude-opus-5-5",
                 nil,
                 1024,
                 messages,
                 %Normandy.Agents.BaseAgentOutputSchema{},
                 []
               )

      assert response.chat_message == "served"
    end
  end

  describe "temperature on the wire" do
    test "a nil temperature is left out of the Messages request" do
      test_pid = self()

      Req.Test.stub(__MODULE__.TemperatureStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => [%{"type" => "text", "text" => ~s({"chat_message": "hi"})}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      client = %Normandy.LLM.ClaudioAdapter{
        api_key: "k",
        options: %{req_options: [plug: {Req.Test, __MODULE__.TemperatureStub}, retry: false]}
      }

      Model.converse(
        client,
        "claude-opus-5-5",
        nil,
        1024,
        [%Normandy.Components.Message{role: "user", content: "hi"}],
        %Normandy.Agents.BaseAgentOutputSchema{},
        []
      )

      assert_received {:request_body, body}
      refute Map.has_key?(body, "temperature")
    end
  end
end
