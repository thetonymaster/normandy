defmodule CustomerSupport.ChatSession do
  @moduledoc """
  Manages customer support chat sessions with agent routing.

  Each session maintains:
  - Unique session ID
  - Conversation history
  - Current agent assignment
  - LLM client for agent communication
  """

  use GenServer
  require Logger

  alias CustomerSupport.Agents.{
    GreeterAgent,
    OrderSupportAgent,
    TechnicalSupportAgent,
    BillingSupportAgent
  }

  @table_name :chat_sessions

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new chat session.
  """
  def create_session do
    GenServer.call(__MODULE__, :create_session)
  end

  @doc """
  Send a message to a chat session.
  """
  def send_message(session_id, message) do
    GenServer.call(__MODULE__, {:send_message, session_id, message}, 60_000)
  end

  @doc """
  Get conversation history for a session.
  """
  def get_history(session_id) do
    GenServer.call(__MODULE__, {:get_history, session_id})
  end

  @doc """
  End a chat session.
  """
  def end_session(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("ChatSession initialized")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:create_session, _from, state) do
    session_id = generate_session_id()

    client = create_llm_client()

    session = %{
      session_id: session_id,
      created_at: DateTime.utc_now(),
      current_agent: :greeter,
      agents: %{},
      history: [],
      client: client
    }

    # Initialize greeter agent
    {:ok, greeter} = GreeterAgent.new(client: client)
    session = put_in(session, [:agents, :greeter], greeter)

    :ets.insert(@table_name, {session_id, session})
    Logger.info("Created session: #{session_id}")

    {:reply, {:ok, session_id}, state}
  end

  @impl true
  def handle_call({:send_message, session_id, message}, _from, state) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, session}] ->
        result = process_message(session, message)
        {:reply, result, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_history, session_id}, _from, state) do
    case :ets.lookup(@table_name, session_id) do
      [{^session_id, session}] ->
        {:reply, {:ok, session.history}, state}

      [] ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    :ets.delete(@table_name, session_id)
    Logger.info("Ended session: #{session_id}")
    {:reply, :ok, state}
  end

  # Private Functions

  defp generate_session_id do
    "session-#{:rand.uniform(999999) |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  defp create_llm_client do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      Logger.warning("ANTHROPIC_API_KEY not set, agents will fail")
    end

    %Normandy.LLM.ClaudioAdapter{
      api_key: api_key,
      options: %{
        timeout: 60_000,
        enable_caching: true
      }
    }
  end

  defp process_message(session, message) do
    # Add user message to history
    history_entry = %{
      timestamp: DateTime.utc_now(),
      role: :user,
      content: message
    }

    session = Map.update!(session, :history, &(&1 ++ [history_entry]))

    # Determine which agent to use
    {agent_type, session} = determine_agent(session, message)

    # Get or create agent
    {agent, session} = get_or_create_agent(session, agent_type)

    # Run agent
    case run_agent_safely(agent, agent_type, message) do
      {:ok, {updated_agent, response}} ->
        # Update agent state
        session = put_in(session, [:agents, agent_type], updated_agent)
        session = Map.put(session, :current_agent, agent_type)

        # Extract response text
        response_text = extract_response_text(response)

        # Add assistant response to history
        assistant_entry = %{
          timestamp: DateTime.utc_now(),
          role: :assistant,
          agent: agent_type,
          content: response_text
        }

        session = Map.update!(session, :history, &(&1 ++ [assistant_entry]))

        # Save session
        :ets.insert(@table_name, {session.session_id, session})

        {:ok, response_text}

      {:error, reason} ->
        Logger.error("Agent execution failed: #{inspect(reason)}")
        {:error, "I'm having trouble processing your request. Please try again."}
    end
  end

  defp determine_agent(session, message) do
    # If not first message and already with specialist, stay with them unless explicitly changing
    if session.current_agent != :greeter and not changing_topic?(message) do
      {session.current_agent, session}
    else
      # Use greeter to classify
      classification = GreeterAgent.classify_query(message)

      agent_type =
        case classification do
          :order -> :order_support
          :technical -> :technical_support
          :billing -> :billing_support
          _ -> :greeter
        end

      {agent_type, session}
    end
  end

  defp changing_topic?(message) do
    message_lower = String.downcase(message)

    Enum.any?(
      [
        "different question",
        "something else",
        "another issue",
        "also need help with",
        "new question"
      ],
      fn phrase -> String.contains?(message_lower, phrase) end
    )
  end

  defp get_or_create_agent(session, agent_type) do
    case Map.get(session.agents, agent_type) do
      nil ->
        {:ok, agent} = create_agent(agent_type, session.client)
        session = put_in(session, [:agents, agent_type], agent)
        {agent, session}

      agent ->
        {agent, session}
    end
  end

  defp create_agent(:greeter, client), do: GreeterAgent.new(client: client)
  defp create_agent(:order_support, client), do: OrderSupportAgent.new(client: client)
  defp create_agent(:technical_support, client), do: TechnicalSupportAgent.new(client: client)
  defp create_agent(:billing_support, client), do: BillingSupportAgent.new(client: client)

  defp run_agent_safely(agent, agent_type, message) do
    try do
      case agent_type do
        :greeter -> {:ok, GreeterAgent.run(agent, message)}
        :order_support -> {:ok, OrderSupportAgent.run(agent, message)}
        :technical_support -> {:ok, TechnicalSupportAgent.run(agent, message)}
        :billing_support -> {:ok, BillingSupportAgent.run(agent, message)}
      end
    rescue
      error ->
        Logger.error("Agent error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp extract_response_text(response) when is_binary(response), do: response

  defp extract_response_text(response) when is_map(response) do
    cond do
      Map.has_key?(response, :chat_message) ->
        response.chat_message

      Map.has_key?(response, :content) and is_list(response.content) ->
        response.content
        |> Enum.map(&extract_content_block/1)
        |> Enum.join("\n")

      true ->
        inspect(response)
    end
  end

  defp extract_response_text(response), do: inspect(response)

  defp extract_content_block(%{text: text}), do: text
  defp extract_content_block(%{type: "text", text: text}), do: text
  defp extract_content_block(_), do: ""
end
