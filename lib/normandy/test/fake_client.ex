defmodule Normandy.Test.FakeClient do
  @moduledoc """
  A scripted model client for tests: no network, no API key, no `Normandy.Agents.Model`
  implementation of your own.

  `new/2` takes the replies in call order. Each request takes the next one, whichever
  process makes it (`Normandy.Agents.BaseAgent.run/3`, `Normandy.Agents.BaseAgent.stream/3`,
  a `Normandy.Agents.Turn.Session`'s server, a `Normandy.Coordination.AgentProcess`), as
  long as it runs on the node that built the client. `requests/1` returns every request
  received so far, oldest first, as `Normandy.LLM.Request` structs.

      client =
        Normandy.Test.FakeClient.new([
          {:tool_calls, [{"weather", %{"city" => "Oslo"}}]},
          {:text, "Cold."}
        ])

      agent =
        Normandy.Agents.BaseAgent.init(client: client, model: "claude-opus-5-5")
        |> Normandy.Agents.BaseAgent.register_tool(%MyApp.WeatherTool{})

      {:ok, _agent, %{chat_message: "Cold."}} =
        Normandy.Agents.BaseAgent.run(agent, "Weather in Oslo?")

      [_tool_round, final_request] = Normandy.Test.FakeClient.requests(client)

  ## Script items

    * `{:text, text}` - the answer text. `text` is a binary, or a list of binaries that
      `stream/3` sends as one text delta each (`converse/3` joins them). For an output
      schema other than the chat schema, the text is parsed into it as JSON, as the
      Claudio adapter parses a model's text (the client's `:on_parse_failure` applies).
    * `{:structured, map}` - a structured answer: `map` encoded as JSON, then parsed into
      the request's response model, or sent as the text of a tool loop's final answer.
    * `{:tool_calls, calls}` - one or more tool calls. Each call is `{name, input}` (its
      id is `"toolu_fake_<request>_<position>"`, both counted from 0) or a
      `%Normandy.Components.ToolCall{}` used as given. Only a request that lists tools
      takes them: scripted for one that lists none, they raise.
    * `{:error, %Normandy.LLMError{}}` - the call fails with that error; its `retryable?`
      decides whether a configured `retry:` resends the request.
    * a 1-arity function - called with the `%Normandy.LLM.Request{}`; returns one of the
      items above.

  `:text`, `:structured` and `:tool_calls` take a keyword list as a third element:

    * `:stop_reason` - the response's stop reason (default `:tool_use` for tool calls,
      `:end_turn` otherwise). `:max_tokens` and `:refusal` make Normandy return
      `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`.
    * `:usage` - the usage map the response reports (default `nil`, no usage), for
      example `%{input_tokens: 12, output_tokens: 3}`.
    * `:stream_error_after` - streaming only: the stream ends in a transport error after
      this many content deltas (at its end when the reply has fewer).

  `new/2` checks every item and raises `ArgumentError` naming the first bad one.

  ## The end of the script

  A request past the last item raises `Normandy.Test.FakeClient.ScriptExhaustedError`:
  `run/3` and `stream/3` raise it, and a `Normandy.Agents.Turn.Server` replies
  `{:error, %Normandy.TurnError{type: :task_down}}` whose `reason` is the exception. With
  `retry:` configured, BaseAgent retries a raised call, so each retry takes a request
  index too. `remaining/1` tells how many items no request has taken.

  The requests live in an ETS table owned by the process that called `new/2`: build the
  client in the test process, not in `setup_all` or a task that exits before the test
  ends.
  """

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.LLM.Call
  alias Normandy.LLM.ParseFailure
  alias Normandy.LLM.Request
  alias Normandy.LLM.Response
  alias Normandy.LLMError

  defmodule ScriptExhaustedError do
    @moduledoc "A `Normandy.Test.FakeClient` received more requests than it has script items."
    defexception [:index, :scripted]

    @impl true
    def message(%__MODULE__{index: index, scripted: scripted}),
      do:
        "Normandy.Test.FakeClient: request #{index} has no scripted reply " <>
          "(#{scripted} scripted); add an item to the script passed to new/2"
  end

  @enforce_keys [:script, :counter, :table]
  defstruct [:script, :counter, :table, options: %{}]

  @type call :: {String.t(), map()} | ToolCall.t()
  @type item_opts :: [
          stop_reason: Response.stop_reason(),
          usage: map() | nil,
          stream_error_after: non_neg_integer()
        ]
  @type item ::
          {:text, String.t() | [String.t()]}
          | {:text, String.t() | [String.t()], item_opts()}
          | {:structured, map()}
          | {:structured, map(), item_opts()}
          | {:tool_calls, [call(), ...]}
          | {:tool_calls, [call(), ...], item_opts()}
          | {:error, LLMError.t()}
          | (Request.t() -> item())

  @type t :: %__MODULE__{
          script: tuple(),
          counter: :atomics.atomics_ref(),
          table: :ets.tid(),
          options: map()
        }

  @new_schema NimbleOptions.new!(
                options: [
                  type: {:custom, Normandy.Options, :plain_map, []},
                  default: %{},
                  doc:
                    "The client's `options` map, read as a real client's would be (for " <>
                      "example `%{on_parse_failure: :error}`)."
                ]
              )

  @item_opts [:stop_reason, :usage, :stream_error_after]

  @doc """
  A client that answers its requests with `script`, in order.

  ## Options

  #{Normandy.Options.docs(@new_schema)}
  """
  @spec new([item()], keyword()) :: t()
  def new(script, opts \\ [])

  def new(script, opts) when is_list(script) do
    opts = Normandy.Options.validate!(opts, @new_schema, {__MODULE__, :new, 2})

    script
    |> Enum.with_index()
    |> Enum.each(fn {item, index} ->
      check_item!(item, "Normandy.Test.FakeClient.new/2: script item #{index}")
    end)

    %__MODULE__{
      script: List.to_tuple(script),
      counter: :atomics.new(1, []),
      table: :ets.new(__MODULE__, [:ordered_set, :public]),
      options: Keyword.fetch!(opts, :options)
    }
  end

  def new(script, _opts) do
    raise ArgumentError,
          "Normandy.Test.FakeClient.new/2: expected the script as a list of items, got: " <>
            inspect(script, limit: 5)
  end

  @doc "Every request the client received, oldest first."
  @spec requests(t()) :: [Request.t()]
  def requests(%__MODULE__{table: table}),
    do: table |> :ets.tab2list() |> Enum.map(fn {_index, request} -> request end)

  @doc "How many script items no request has taken yet."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{script: script, counter: counter}),
    do: max(tuple_size(script) - :atomics.get(counter, 1), 0)

  @doc false
  # The item for the next request, which is recorded first. Called by the Model impl.
  @spec next!(t(), Request.t()) :: {non_neg_integer(), item()}
  def next!(%__MODULE__{} = client, %Request{} = request) do
    index = :atomics.add_get(client.counter, 1, 1) - 1
    true = :ets.insert(client.table, {index, request})

    if index >= tuple_size(client.script) do
      raise ScriptExhaustedError, index: index, scripted: tuple_size(client.script)
    end

    case elem(client.script, index) do
      fun when is_function(fun, 1) ->
        item = fun.(request)

        check_item!(
          item,
          "Normandy.Test.FakeClient: the function at script item #{index} returned an item that"
        )

        {index, item}

      item ->
        {index, item}
    end
  end

  @doc false
  # The %Response{} for an item on converse/3.
  @spec response(t(), Request.t(), non_neg_integer(), item()) ::
          {:ok, Response.t()} | {:error, LLMError.t()}
  def response(_client, _request, _index, {:error, %LLMError{} = error}), do: {:error, error}

  def response(client, request, index, item) do
    {kind, value, opts} = split(item)
    check_tools!(request, kind, index)
    stop_reason = Keyword.get(opts, :stop_reason, default_stop(kind))

    case fill(client, request.response_model, kind, value, index, stop_reason) do
      {:error, %LLMError{}} = error ->
        error

      content ->
        {:ok, %Response{content: content, stop_reason: stop_reason, usage: opts[:usage]}}
    end
  end

  @doc false
  # The stream events for an item on stream/3.
  @spec events(Request.t(), non_neg_integer(), item()) :: {:ok, list()} | {:error, LLMError.t()}
  def events(_request, _index, {:error, %LLMError{} = error}), do: {:error, error}

  def events(request, index, item) do
    {kind, value, opts} = split(item)
    check_tools!(request, kind, index)
    stop_reason = opts |> Keyword.get(:stop_reason, default_stop(kind)) |> to_string()
    blocks = stream_blocks(kind, value, index)

    events =
      [
        %{
          type: "message_start",
          message: %{
            "id" => "msg_fake_#{index}",
            "type" => "message",
            "role" => "assistant",
            "model" => request.model,
            "content" => []
          }
        }
      ] ++
        blocks ++
        [
          %{
            type: "message_delta",
            delta: %{"stop_reason" => stop_reason},
            usage: stringify(opts[:usage])
          },
          %{type: "message_stop"}
        ]

    {:ok, cut_stream(events, Keyword.get(opts, :stream_error_after))}
  end

  defp split({kind, value}), do: {kind, value, []}
  defp split({kind, value, opts}), do: {kind, value, opts}

  defp check_tools!(%Request{tools: []}, :tool_calls, index) do
    raise ArgumentError,
          "Normandy.Test.FakeClient: script item #{index} is a :tool_calls reply, but request " <>
            "#{index} lists no tools; only an agent with tools receives tool calls " <>
            "(register a tool, or script a :text or :structured reply)"
  end

  defp check_tools!(_request, _kind, _index), do: :ok

  defp default_stop(:tool_calls), do: :tool_use
  defp default_stop(_kind), do: :end_turn

  defp fill(_client, %ToolCallResponse{} = model, :tool_calls, calls, index, stop),
    do: %{model | tool_calls: tool_calls(calls, index), stop_reason: stop}

  defp fill(_client, model, :tool_calls, _calls, index, _stop) do
    raise ArgumentError,
          "Normandy.Test.FakeClient: script item #{index} is a :tool_calls reply, but request " <>
            "#{index} expects #{describe_model(model)}; only an agent with tools receives " <>
            "tool calls (register a tool, or script a :text or :structured reply)"
  end

  defp fill(client, model, :structured, map, index, stop),
    do: fill(client, model, :text, Normandy.JSON.encode!(map), index, stop)

  defp fill(_client, nil, :text, text, _index, _stop), do: IO.iodata_to_binary(text)

  defp fill(_client, %ToolCallResponse{} = model, :text, text, _index, stop),
    do: %{model | content: IO.iodata_to_binary(text), stop_reason: stop}

  defp fill(_client, %{chat_message: _} = model, :text, text, _index, _stop),
    do: %{model | chat_message: IO.iodata_to_binary(text)}

  # A cut-off or refused answer is not parsed (Normandy turns it into an error).
  defp fill(client, %_{} = model, :text, text, _index, stop) do
    if Call.stop_reason(stop) in [:max_tokens, :model_context_window_exceeded, :refusal],
      do: model,
      else: ParseFailure.parse_text_output(%{client: client}, IO.iodata_to_binary(text), model)
  end

  defp tool_calls(calls, index) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn
      {%ToolCall{} = call, _position} ->
        call

      {{name, input}, position} ->
        %ToolCall{id: "toolu_fake_#{index}_#{position}", name: name, input: input}
    end)
  end

  defp stream_blocks(:tool_calls, calls, index) do
    calls
    |> tool_calls(index)
    |> Enum.with_index()
    |> Enum.flat_map(fn {call, position} ->
      block(
        position,
        %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => %{}},
        [%{"type" => "input_json_delta", "partial_json" => Normandy.JSON.encode!(call.input)}]
      )
    end)
  end

  defp stream_blocks(:structured, map, index),
    do: stream_blocks(:text, Normandy.JSON.encode!(map), index)

  defp stream_blocks(:text, text, _index) do
    chunks = if is_list(text), do: text, else: [text]

    block(
      0,
      %{"type" => "text", "text" => ""},
      Enum.map(chunks, &%{"type" => "text_delta", "text" => &1})
    )
  end

  defp block(index, start, deltas) do
    [%{type: "content_block_start", index: index, content_block: start}] ++
      Enum.map(deltas, &%{type: "content_block_delta", index: index, delta: &1}) ++
      [%{type: "content_block_stop", index: index}]
  end

  # The events up to the n-th content delta, then a transport error.
  defp cut_stream(events, nil), do: events

  defp cut_stream(events, n) do
    {kept, _rest} =
      Enum.reduce_while(events, {[], 0}, fn
        %{type: "content_block_delta"}, {acc, ^n} -> {:halt, {acc, n}}
        %{type: "content_block_delta"} = event, {acc, seen} -> {:cont, {[event | acc], seen + 1}}
        event, {acc, seen} -> {:cont, {[event | acc], seen}}
      end)

    Enum.reverse([{:error, :closed} | kept])
  end

  defp stringify(nil), do: nil
  defp stringify(usage), do: Map.new(usage, fn {key, value} -> {to_string(key), value} end)

  defp describe_model(nil), do: "a text answer (response_model nil)"
  defp describe_model(%module{}), do: "%#{inspect(module)}{}"

  # ── Script checks ─────────────────────────────────────────────────────────────

  @shape "expected {:text, text}, {:structured, map}, {:tool_calls, calls} (each with an " <>
           "optional keyword list of :stop_reason, :usage, :stream_error_after), " <>
           "{:error, %Normandy.LLMError{}} or a 1-arity function"

  defp check_item!(fun, _where) when is_function(fun, 1), do: :ok
  defp check_item!({:error, %LLMError{}}, _where), do: :ok

  defp check_item!({kind, value}, where) when kind in [:text, :structured, :tool_calls],
    do: check_value!(kind, value, where)

  defp check_item!({kind, value, opts} = item, where)
       when kind in [:text, :structured, :tool_calls] do
    check_value!(kind, value, where)
    check_opts!(opts, item, where)
  end

  defp check_item!(item, where), do: bad!(where, "is #{inspect(item, limit: 5)}; #{@shape}")

  defp check_value!(:text, text, _where) when is_binary(text), do: :ok

  defp check_value!(:text, [_ | _] = chunks, where) do
    if Enum.all?(chunks, &is_binary/1),
      do: :ok,
      else: bad!(where, "is a :text reply whose list holds a non-binary chunk")
  end

  defp check_value!(:structured, map, _where) when is_map(map) and not is_struct(map), do: :ok

  defp check_value!(:tool_calls, [_ | _] = calls, where) do
    case Enum.find(calls, &(not call?(&1))) do
      nil ->
        :ok

      call ->
        bad!(
          where,
          "is a :tool_calls reply with the call #{inspect(call, limit: 5)}; expected " <>
            "{name, input} (a binary and a map) or a %Normandy.Components.ToolCall{}"
        )
    end
  end

  defp check_value!(kind, value, where),
    do: bad!(where, "is a #{inspect(kind)} reply with #{inspect(value, limit: 5)}; #{@shape}")

  defp call?({name, input}) when is_binary(name) and is_map(input), do: true
  defp call?(%ToolCall{}), do: true
  defp call?(_call), do: false

  defp check_opts!(opts, item, where) do
    unless Keyword.keyword?(opts),
      do: bad!(where, "is #{inspect(item, limit: 5)}; its third element must be a keyword list")

    case Keyword.keys(opts) -- @item_opts do
      [] -> :ok
      [key | _] -> bad!(where, "has unknown option #{inspect(key)}; supported: #{supported()}")
    end

    check_opt!(:stop_reason, opts[:stop_reason], &(is_atom(&1) or is_binary(&1)), where)
    check_opt!(:usage, opts[:usage], &(is_nil(&1) or is_map(&1)), where)

    check_opt!(
      :stream_error_after,
      opts[:stream_error_after],
      &(is_nil(&1) or (is_integer(&1) and &1 >= 0)),
      where
    )
  end

  defp check_opt!(_key, nil, _valid?, _where), do: :ok

  defp check_opt!(key, value, valid?, where) do
    if valid?.(value),
      do: :ok,
      else: bad!(where, "has an invalid #{inspect(key)}: #{inspect(value, limit: 5)}")
  end

  defp supported, do: Enum.map_join(@item_opts, ", ", &inspect/1)

  @spec bad!(String.t(), String.t()) :: no_return()
  defp bad!(where, detail), do: raise(ArgumentError, "#{where} #{detail}")

  defimpl Normandy.Agents.Model do
    alias Normandy.Test.FakeClient

    def converse(client, request, _opts) do
      {index, item} = FakeClient.next!(client, request)
      FakeClient.response(client, request, index, item)
    end

    def stream(client, request, _opts) do
      {index, item} = FakeClient.next!(client, request)
      FakeClient.events(request, index, item)
    end
  end
end
