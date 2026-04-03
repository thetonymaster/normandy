defmodule Normandy.A2A.AgentTool do
  @moduledoc """
  Wraps a remote A2A agent as a Normandy `BaseTool`.

  When the LLM calls this tool, a message is sent to the remote agent
  via the A2A protocol and the result is returned.

  ## Example

      alias Normandy.A2A.AgentTool

      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")

      tool = AgentTool.new("https://agent.example.com/a2a", card,
        auth_token: "bearer-token",
        timeout: 30_000
      )

      agent = BaseAgent.register_tool(agent, tool)

  """

  @default_timeout 60_000
  @poll_interval 1_000

  @type t :: %__MODULE__{
          endpoint: String.t(),
          agent_card: Claudio.A2A.AgentCard.t(),
          skill_id: String.t() | nil,
          auth_token: String.t() | nil,
          transport_opts: keyword(),
          timeout: pos_integer(),
          input: map()
        }

  defstruct [
    :endpoint,
    :agent_card,
    :skill_id,
    :auth_token,
    transport_opts: [],
    timeout: @default_timeout,
    input: %{}
  ]

  @doc """
  Creates a new AgentTool for a remote A2A agent.

  ## Options

    - `:skill_id` - Specific skill to expose (nil for general agent access)
    - `:auth_token` - Bearer token for authentication
    - `:transport_opts` - Options passed to the A2A transport
    - `:timeout` - Maximum time to wait for task completion (default: 60s)

  """
  @spec new(String.t(), Claudio.A2A.AgentCard.t(), keyword()) :: t()
  def new(endpoint, agent_card, opts \\ []) do
    %__MODULE__{
      endpoint: endpoint,
      agent_card: agent_card,
      skill_id: Keyword.get(opts, :skill_id),
      auth_token: Keyword.get(opts, :auth_token),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  @doc """
  Prepares the tool with LLM-provided input parameters.
  """
  @spec prepare_input(t(), map()) :: t()
  def prepare_input(%__MODULE__{} = tool, input) when is_map(input) do
    %{tool | input: input}
  end

  @doc false
  def sanitize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim_leading("_")
    |> String.trim_trailing("_")
  end

  @doc false
  def poll_for_result(endpoint, task_id, opts, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, "Task timed out waiting for completion"}
    else
      case Claudio.A2A.Client.get_task(endpoint, task_id, opts) do
        {:ok, task} ->
          if Claudio.A2A.Task.terminal?(task) do
            extract_task_result(task)
          else
            Process.sleep(@poll_interval)
            poll_for_result(endpoint, task_id, opts, deadline)
          end

        {:error, reason} ->
          {:error, "Failed to get task status: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  def extract_task_result(%{status: %{state: state}} = task) when state in [:completed] do
    text =
      case task.artifacts do
        [artifact | _] ->
          artifact.parts
          |> Enum.map(fn part -> Map.get(part, :text, "") end)
          |> Enum.join("\n")

        _ ->
          case task.status do
            %{message: %{parts: parts}} when is_list(parts) ->
              parts |> Enum.map(fn p -> Map.get(p, :text, "") end) |> Enum.join("\n")

            _ ->
              "Task completed"
          end
      end

    {:ok, text}
  end

  @doc false
  def extract_task_result(%{status: %{state: state, message: message}})
      when state in [:failed, :rejected] do
    error_text =
      case message do
        %{parts: parts} when is_list(parts) ->
          parts |> Enum.map(fn p -> Map.get(p, :text, "") end) |> Enum.join("\n")

        _ ->
          "Task #{state}"
      end

    {:error, error_text}
  end

  @doc false
  def extract_task_result(%{status: %{state: state}}) do
    {:error, "Task ended in unexpected state: #{state}"}
  end

  defimpl Normandy.Tools.BaseTool do
    alias Normandy.A2A.AgentTool

    def tool_name(%{agent_card: card, skill_id: nil}) do
      "a2a__#{AgentTool.sanitize_name(card.name)}"
    end

    def tool_name(%{agent_card: card, skill_id: skill_id}) do
      "a2a__#{AgentTool.sanitize_name(card.name)}__#{AgentTool.sanitize_name(skill_id)}"
    end

    def tool_description(%{agent_card: card, skill_id: nil}) do
      "Remote A2A agent: #{card.description}"
    end

    def tool_description(%{agent_card: card, skill_id: skill_id}) do
      skill = Enum.find(card.skills, fn s -> s.id == skill_id end)

      if skill do
        "#{card.name} - #{skill.description}"
      else
        "Remote A2A agent: #{card.description} (skill: #{skill_id})"
      end
    end

    def input_schema(_tool) do
      %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "Message to send to the remote agent"
          }
        },
        "required" => ["message"]
      }
    end

    def run(%{
          endpoint: endpoint,
          auth_token: auth_token,
          transport_opts: transport_opts,
          timeout: timeout,
          input: input
        }) do
      message_text = Map.get(input, "message") || Map.get(input, :message, "")

      message =
        Claudio.A2A.Message.new(:user, [
          Claudio.A2A.Part.text(message_text)
        ])

      opts =
        transport_opts
        |> Keyword.merge(if(auth_token, do: [auth_token: auth_token], else: []))

      case Claudio.A2A.Client.send_message(endpoint, message, opts) do
        {:ok, %Claudio.A2A.Task{} = task} ->
          if Claudio.A2A.Task.terminal?(task) do
            AgentTool.extract_task_result(task)
          else
            deadline = System.monotonic_time(:millisecond) + timeout
            AgentTool.poll_for_result(endpoint, task.id, opts, deadline)
          end

        {:ok, %Claudio.A2A.Message{} = response_msg} ->
          text =
            response_msg.parts
            |> Enum.map(fn part -> Map.get(part, :text, "") end)
            |> Enum.join("\n")

          {:ok, text}

        {:error, reason} ->
          {:error, "A2A request failed: #{inspect(reason)}"}
      end
    end
  end
end
