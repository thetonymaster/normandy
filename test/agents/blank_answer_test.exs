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
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.StubClient

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
end
