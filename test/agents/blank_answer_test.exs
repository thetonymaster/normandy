defmodule Normandy.Agents.BlankAnswerTest do
  @moduledoc """
  Decision 22: an empty or whitespace-only final answer is the `:invalid_output`
  LLMError on every path, including a chat agent with no tools (whose response model
  is the output schema, so the answer is only validated, never converted). The one
  exception: a chat agent whose last tool-calling response in the turn carried text
  answers that text.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.OwnLog
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture

  @message "expected a final answer, got an empty one: the model ended its turn with no text"

  defp chat_agent(text),
    do: BaseAgent.init(%{client: FakeClient.new([{:text, text}]), model: "m", max_tokens: 64})

  for text <- ["", "  \n"] do
    @text text

    test "run/3: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      assert {:error, %LLMError{type: :invalid_output} = error} =
               BaseAgent.run(chat_agent(@text), "hi")

      assert Exception.message(error) =~ @message
    end

    test "stream/3: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      assert {:error, %LLMError{type: :invalid_output} = error} =
               BaseAgent.stream(chat_agent(@text), "hi", fn _event -> :ok end)

      assert Exception.message(error) =~ @message
    end

    test "Turn.Server: a no-tool chat agent's blank answer #{inspect(text)} is :invalid_output" do
      sid = "s-blank-#{System.unique_integer([:positive])}"

      {:ok, srv} =
        Server.start_link(
          session_id: sid,
          config: chat_agent(@text),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, %LLMError{type: :invalid_output} = error} =
               Server.run(srv, %{chat_message: "hi"})

      assert Exception.message(error) =~ @message
    end
  end

  test "a non-blank answer still succeeds on run/3 and Turn.Server" do
    assert {:ok, _config, %{chat_message: "Hello"}} = BaseAgent.run(chat_agent("Hello"), "hi")

    {:ok, srv} =
      Server.start_link(
        session_id: "s-blank-ok",
        config: chat_agent("Hello"),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %{chat_message: "Hello"}} = Server.run(srv, %{chat_message: "hi"})
  end

  # Decision 27 A3: a client that returns the answer struct itself can leave
  # chat_message nil, and a tool loop's final response can carry no text at all. Neither
  # is an answer. (A stream builds its answer from text deltas, so it never holds nil.)
  describe "a nil chat_message" do
    defp nil_answer_agents do
      chat =
        BaseAgent.init(%{
          client: %StubClient{reply: fn _ -> %BaseAgentOutputSchema{chat_message: nil} end},
          model: "m"
        })

      tools =
        %{client: %StubClient{reply: fn _ -> %ToolCallResponse{content: nil} end}, model: "m"}
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ReturnTool{})

      [chat: chat, tools: tools]
    end

    test "run/3 returns :invalid_output for a chat agent and a tool loop" do
      for {_kind, agent} <- nil_answer_agents() do
        assert {:error, %LLMError{type: :invalid_output} = error} = BaseAgent.run(agent, "hi")
        assert Exception.message(error) =~ @message
      end
    end

    test "Turn.Server replies :invalid_output for a chat agent and a tool loop" do
      for {kind, agent} <- nil_answer_agents() do
        {:ok, srv} =
          Server.start_link(
            session_id: "s-nil-#{kind}-#{System.unique_integer([:positive])}",
            config: agent,
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()}
          )

        assert {:error, %LLMError{type: :invalid_output} = error} =
                 Server.run(srv, %{chat_message: "hi"})

        assert Exception.message(error) =~ @message
      end
    end
  end

  # A model can answer alongside a tool call ([text, tool_use]) and end the turn blank
  # after the tool result (e2e 16 Part B). For a chat agent, the text of this turn's last
  # tool-call response is then the answer; nothing else changes.
  describe "a blank final answer after a tool round that answered" do
    defmodule Answer do
      @moduledoc false
      use Normandy.Schema

      io_schema "the agent's answer" do
        field(:city, :string, description: "the city", required: true)
      end
    end

    # A FakeClient whose replies at the indexes in `texts` also carry that text beside
    # their tool calls (FakeClient scripts tool calls with no text).
    defmodule LeadTextClient do
      @moduledoc false
      defstruct [:fake, texts: %{}]

      defimpl Normandy.Agents.Model do
        alias Normandy.Agents.Model
        alias Normandy.Agents.ToolCallResponse
        alias Normandy.LLM.Response
        alias Normandy.Test.FakeClient

        def converse(client, request, opts) do
          result = Model.converse(client.fake, request, opts)

          case {result, Map.get(client.texts, last_index(client))} do
            {{:ok, %Response{content: %ToolCallResponse{} = r} = resp}, text}
            when is_binary(text) ->
              {:ok, %{resp | content: %{r | content: text}}}

            _ ->
              result
          end
        end

        def stream(client, request, opts) do
          result = Model.stream(client.fake, request, opts)

          case {result, Map.get(client.texts, last_index(client))} do
            {{:ok, events}, text} when is_binary(text) -> {:ok, lead_text(events, text)}
            _ -> result
          end
        end

        defp last_index(client), do: length(FakeClient.requests(client.fake)) - 1

        # A text block at index 0, the reply's own blocks shifted after it.
        defp lead_text([start | rest], text) do
          shifted = Enum.map(rest, &shift/1)

          text_block = [
            %{
              type: "content_block_start",
              index: 0,
              content_block: %{"type" => "text", "text" => ""}
            },
            %{
              type: "content_block_delta",
              index: 0,
              delta: %{"type" => "text_delta", "text" => text}
            },
            %{type: "content_block_stop", index: 0}
          ]

          [start | text_block ++ shifted]
        end

        defp shift(%{index: index} = event), do: %{event | index: index + 1}
        defp shift(event), do: event
      end
    end

    defp lead_text_agent(script, texts, extra \\ %{}) do
      client = %LeadTextClient{fake: FakeClient.new(script), texts: texts}

      %{client: client, model: "m", max_tokens: 64}
      |> Map.merge(extra)
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ReturnTool{name: "record_city", output: "recorded"})
    end

    defp turns(:run, agent, inputs), do: config_turns(agent, inputs, &BaseAgent.run/2)

    defp turns(:stream, agent, inputs),
      do: config_turns(agent, inputs, &BaseAgent.stream(&1, &2, fn _event -> :ok end))

    defp turns(:server, agent, inputs) do
      {:ok, srv} =
        Server.start_link(
          session_id: "s-lead-#{System.unique_integer([:positive])}",
          config: agent,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      Enum.map(inputs, fn
        nil -> Server.run(srv, nil)
        input -> Server.run(srv, %{chat_message: input})
      end)
    end

    defp config_turns(agent, inputs, run) do
      {results, _config} =
        Enum.map_reduce(inputs, agent, fn input, config ->
          case run.(config, input) do
            {:ok, config, output} -> {{:ok, output}, config}
            {:error, _} = error -> {error, config}
          end
        end)

      results
    end

    for path <- [:run, :stream, :server], blank <- ["", "  "] do
      @path path
      @blank blank

      test "#{path}: a chat agent's blank #{inspect(blank)} after [text, tool call] answers that text" do
        agent =
          lead_text_agent([{:tool_calls, [{"record_city", %{}}]}, {:text, @blank}], %{
            0 => "Paris."
          })

        assert [{:ok, %{chat_message: "Paris."}}] = turns(@path, agent, ["Capital of France?"])
      end
    end

    # run(_, nil) continues the conversation under the same turn_id: the previous run's
    # final answer ends what counts, so its tool-round text never answers the continuation.
    for path <- [:run, :server] do
      @path path

      test "#{path}: a nil-input continuation's blank answer does not reuse the answered run's tool-round text" do
        agent =
          lead_text_agent(
            [{:tool_calls, [{"record_city", %{}}]}, {:text, "Final."}, {:text, ""}],
            %{0 => "Paris."}
          )

        assert [
                 {:ok, %{chat_message: "Final."}},
                 {:error, %LLMError{type: :invalid_output} = error}
               ] = turns(@path, agent, ["Capital of France?", nil])

        assert Exception.message(error) =~ @message
      end
    end

    # A Turn.Server turn that fails after its tool round keeps that round in memory with no
    # final answer after it; only the turn boundary keeps its text from answering the next
    # turn. (run/3 and stream/3 hand back no config on failure, so they have no such state.)
    test "server: a failed turn's tool-round text never answers the next turn" do
      agent =
        lead_text_agent(
          [
            {:tool_calls, [{"record_city", %{}}]},
            {:error, LLMError.new(type: :server, retryable?: false)},
            {:text, ""}
          ],
          %{0 => "Paris."}
        )

      assert [
               {:error, %LLMError{type: :server}},
               {:error, %LLMError{type: :invalid_output} = error}
             ] = turns(:server, agent, ["Capital of France?", "Again?"])

      assert Exception.message(error) =~ @message
    end

    for path <- [:run, :stream, :server] do
      @path path

      test "#{path}: a blank answer after a tool call with no text is still :invalid_output" do
        agent = lead_text_agent([{:tool_calls, [{"record_city", %{}}]}, {:text, ""}], %{})

        assert [{:error, %LLMError{type: :invalid_output} = error}] =
                 turns(@path, agent, ["Capital of France?"])

        assert Exception.message(error) =~ @message
      end

      test "#{path}: a structured-output agent's blank answer after [text, tool call] is still :invalid_output" do
        agent =
          lead_text_agent(
            [{:tool_calls, [{"record_city", %{}}]}, {:text, ""}],
            %{0 => "Paris."},
            %{output_schema: %Answer{}}
          )

        assert [{:error, %LLMError{type: :invalid_output}}] =
                 turns(@path, agent, ["Capital of France?"])
      end

      # Turn 1 answers beside its tool call, then gives a normal final answer; turn 2's
      # blank answer must not reach back to turn 1's tool-round text. Without a tool round
      # in turn 2 the walk would meet turn 1's text if neither the turn boundary nor turn
      # 1's final answer stopped it; with one, turn 2's own text-less round is found first.
      for {label, turn2} <- [
            {"no tool round", [{:text, ""}]},
            {"a tool round with no text", [{:tool_calls, [{"record_city", %{}}]}, {:text, ""}]}
          ] do
        @turn2 turn2

        test "#{path}: an earlier turn's tool-round text never answers a later turn (#{label})" do
          agent =
            lead_text_agent(
              [{:tool_calls, [{"record_city", %{}}]}, {:text, "Final."}] ++ @turn2,
              %{0 => "Rome."}
            )

          assert [
                   {:ok, %{chat_message: "Final."}},
                   {:error, %LLMError{type: :invalid_output} = error}
                 ] = turns(@path, agent, ["Capital of Italy?", "Record it."])

          assert Exception.message(error) =~ @message
        end
      end
    end
  end

  # Memory stores the substituted answer twice (the tool round's text and the final
  # answer); the next request shows the model the sentence once, and memory still ends
  # with the answer (Turn.answered?/1).
  describe "the next request after a tool-round answer" do
    defp request_texts(%Normandy.LLM.Request{messages: messages}), do: texts(messages)

    defp texts(messages) do
      Enum.flat_map(messages, fn
        %{content: text} when is_binary(text) ->
          [text]

        %{content: blocks} when is_list(blocks) ->
          Enum.flat_map(blocks, fn
            %{type: "text", text: text} -> [text]
            %{"type" => "text", "text" => text} -> [text]
            _block -> []
          end)
      end)
    end

    defp second_request(client) do
      [_, _, request] = FakeClient.requests(client.fake)
      request
    end

    for path <- [:run, :stream] do
      @path path

      test "#{path}: holds the sentence once; memory still ends answered" do
        agent =
          lead_text_agent(
            [{:tool_calls, [{"record_city", %{}}]}, {:text, ""}, {:text, "You're welcome."}],
            %{0 => "Paris."}
          )

        run =
          case @path do
            :run -> &BaseAgent.run/2
            :stream -> &BaseAgent.stream(&1, &2, fn _event -> :ok end)
          end

        assert {:ok, config, %{chat_message: "Paris."}} = run.(agent, "Capital of France?")

        assert Turn.answered?(AgentMemory.messages(config.memory))

        assert {:ok, _config, %{chat_message: "You're welcome."}} = run.(config, "Thanks")

        texts = request_texts(second_request(agent.client))
        assert Enum.count(texts, &(&1 == "Paris.")) == 1
        assert List.last(texts) == "Thanks"
      end
    end

    test "server: holds the sentence once; the stored history still ends answered" do
      agent =
        lead_text_agent(
          [{:tool_calls, [{"record_city", %{}}]}, {:text, ""}, {:text, "You're welcome."}],
          %{0 => "Paris."}
        )

      sid = "s-once-#{System.unique_integer([:positive])}"
      store = InMemory.new()

      assert [{:ok, %{chat_message: "Paris."}}, {:ok, %{chat_message: "You're welcome."}}] =
               turns_on(agent, sid, store, ["Capital of France?", "Thanks"])

      texts = request_texts(second_request(agent.client))
      assert Enum.count(texts, &(&1 == "Paris.")) == 1

      {:ok, entries} = InMemory.history(store, sid)
      memory = AgentMemory.from_entries(entries)

      assert Turn.answered?(AgentMemory.messages(memory))

      history = AgentMemory.history(memory)
      assert Enum.count(texts(history), &(&1 == "Paris.")) == 2
    end

    defp turns_on(agent, sid, store, inputs) do
      {:ok, srv} =
        Server.start_link(
          session_id: sid,
          config: agent,
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      Enum.map(inputs, &Server.run(srv, %{chat_message: &1}))
    end
  end

  # The substitution above is marked on the run :stop (answer_source), on every shell;
  # a failed run's :exception carries no answer_source.
  describe "run :stop answer_source" do
    for path <- [:run, :stream, :server] do
      @path path

      test "#{path}: an answer taken from the tool round is answer_source: :tool_round" do
        name = "answer-source-#{System.unique_integer([:positive])}"
        TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: name)

        agent =
          lead_text_agent(
            [{:tool_calls, [{"record_city", %{}}]}, {:text, ""}],
            %{0 => "Paris."},
            %{name: name}
          )

        assert [{:ok, %{chat_message: "Paris."}}] = turns(@path, agent, ["Capital of France?"])
        assert_receive {:span, [:normandy, :agent, :run, :stop], meta}
        assert meta.answer_source == :tool_round
      end

      test "#{path}: a final answer is answer_source: :final" do
        name = "answer-source-#{System.unique_integer([:positive])}"
        TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: name)

        agent =
          lead_text_agent(
            [{:tool_calls, [{"record_city", %{}}]}, {:text, "Paris it is."}],
            %{0 => "Paris."},
            %{name: name}
          )

        assert [{:ok, %{chat_message: "Paris it is."}}] =
                 turns(@path, agent, ["Capital of France?"])

        assert_receive {:span, [:normandy, :agent, :run, :stop], meta}
        assert meta.answer_source == :final
      end

      test "#{path}: a failed run's :exception has no answer_source" do
        name = "answer-source-#{System.unique_integer([:positive])}"
        TelemetryCapture.attach_span([[:normandy, :agent, :run, :exception]], agent_name: name)

        agent =
          lead_text_agent([{:tool_calls, [{"record_city", %{}}]}, {:text, ""}], %{}, %{
            name: name
          })

        assert [{:error, %LLMError{type: :invalid_output}}] =
                 turns(@path, agent, ["Capital of France?"])

        assert_receive {:span, [:normandy, :agent, :run, :exception], meta}
        refute Map.has_key?(meta, :answer_source)
      end
    end

    test "run/3: the substitution logs one debug line with the turn id and no answer text" do
      agent =
        lead_text_agent([{:tool_calls, [{"record_city", %{}}]}, {:text, ""}], %{
          0 => "Secret Paris."
        })

      log =
        OwnLog.capture([level: :debug, metadata: [:turn_id]], fn ->
          assert [{:ok, %{chat_message: "Secret Paris."}}] =
                   turns(:run, agent, ["Capital of France?"])
        end)

      assert [line] =
               log
               |> String.split("\n")
               |> Enum.filter(&(&1 =~ "answer taken from the tool round"))

      assert line =~ ~r/turn_id=[0-9a-f-]{36}/
      refute log =~ "Secret Paris."
    end

    test "run/3: a no-tool chat agent's answer is answer_source: :final" do
      name = "answer-source-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: name)

      agent =
        BaseAgent.init(%{client: FakeClient.new([{:text, "Hello"}]), model: "m", name: name})

      assert {:ok, _config, %{chat_message: "Hello"}} = BaseAgent.run(agent, "hi")
      assert_receive {:span, [:normandy, :agent, :run, :stop], meta}
      assert meta.answer_source == :final
    end
  end
end
