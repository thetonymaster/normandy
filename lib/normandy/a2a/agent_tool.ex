defmodule Normandy.A2A.AgentTool do
  @moduledoc """
  Wraps a remote A2A agent as a `Normandy.Tool`.

  When the LLM calls this tool, a message is sent to the remote agent
  via the A2A protocol and the result is returned.

  ## Example

      alias Normandy.A2A.AgentTool

      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")

      tool = AgentTool.new("https://agent.example.com/a2a", card, auth_token: "bearer-token")

      agent = BaseAgent.register_tool(agent, tool, timeout: 60_000)

  The tool polls a remote task until it ends; the registration `:timeout` (default
  `Normandy.Tools.Executor.default_timeout/0`, 30 s) bounds the whole call, so give a
  remote agent that works for minutes a longer one.
  """

  use Normandy.Tool

  alias Claudio.A2A.Client
  alias Claudio.A2A.Message
  alias Claudio.A2A.Part
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Tools.Context

  @poll_interval 1_000

  @type t :: %__MODULE__{
          endpoint: String.t(),
          agent_card: Claudio.A2A.AgentCard.t(),
          skill_id: String.t() | nil,
          auth_token: String.t() | nil,
          transport_opts: keyword()
        }

  @derive {Inspect, except: [:auth_token]}
  defstruct [
    :endpoint,
    :agent_card,
    :skill_id,
    :auth_token,
    transport_opts: []
  ]

  @doc """
  Creates a new AgentTool for a remote A2A agent.

  ## Options

    - `:skill_id` - Specific skill to expose (nil for general agent access)
    - `:auth_token` - Bearer token for authentication
    - `:transport_opts` - Options passed to the A2A transport. Its `:headers`
      (`[{name, value}]`) are sent on every request; when OpenTelemetry is
      loaded and a span is active, W3C `traceparent`/`tracestate` headers are
      added beside them (a same-named header you set is kept)

  The call's timeout is a registration option:
  `BaseAgent.register_tool(agent, tool, timeout: ms)`. Passing `:timeout` here raises
  `ArgumentError`.
  """
  @spec new(String.t(), Claudio.A2A.AgentCard.t(), keyword()) :: t()
  def new(endpoint, agent_card, opts \\ []) do
    if Keyword.has_key?(opts, :timeout) do
      raise ArgumentError,
            "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
              "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end

    %__MODULE__{
      endpoint: endpoint,
      agent_card: agent_card,
      skill_id: Keyword.get(opts, :skill_id),
      auth_token: Keyword.get(opts, :auth_token),
      transport_opts: Keyword.get(opts, :transport_opts, [])
    }
  end

  @doc false
  # Adds the current OpenTelemetry context as W3C `traceparent`/`tracestate`
  # request headers, so the remote agent's spans join this trace (see
  # `Normandy.A2A.Server.handle_message/3`). A header the caller already set in
  # `transport_opts[:headers]` is kept. No-op without OTel or an active span.
  @spec put_trace_headers(keyword()) :: keyword()
  def put_trace_headers(opts) do
    case OtelCtx.inject(OtelCtx.capture()) do
      [] ->
        opts

      carrier ->
        headers = opts |> Keyword.get(:headers, []) |> Enum.to_list()
        taken = MapSet.new(headers, fn {name, _} -> String.downcase(to_string(name)) end)
        trace = Enum.reject(carrier, fn {name, _} -> String.downcase(name) in taken end)
        Keyword.put(opts, :headers, headers ++ trace)
    end
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
  # `deadline` is a monotonic time in ms, or :infinity when the executor's timeout is the
  # only bound (run/2).
  def poll_for_result(endpoint, task_id, opts, deadline) do
    if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline do
      {:error, "Task timed out waiting for completion"}
    else
      case Client.get_task(endpoint, task_id, opts) do
        {:ok, task} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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
          |> Enum.map_join("\n", fn part -> Map.get(part, :text, "") end)

        _ ->
          case task.status do
            %{message: %{parts: parts}} when is_list(parts) ->
              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              parts |> Enum.map_join("\n", fn p -> Map.get(p, :text, "") end)

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
          parts |> Enum.map_join("\n", fn p -> Map.get(p, :text, "") end)

        _ ->
          "Task #{state}"
      end

    {:error, error_text}
  end

  @doc false
  def extract_task_result(%{status: %{state: state}}) do
    {:error, "Task ended in unexpected state: #{state}"}
  end

  @impl Normandy.Tool
  def name(%__MODULE__{agent_card: card, skill_id: nil}),
    do: "a2a__#{sanitize_name(card.name)}"

  def name(%__MODULE__{agent_card: card, skill_id: skill_id}),
    do: "a2a__#{sanitize_name(card.name)}__#{sanitize_name(skill_id)}"

  @impl Normandy.Tool
  def description(%__MODULE__{agent_card: card, skill_id: nil}),
    do: "Remote A2A agent: #{card.description}"

  def description(%__MODULE__{agent_card: card, skill_id: skill_id}) do
    case Enum.find(card.skills, fn s -> s.id == skill_id end) do
      nil -> "Remote A2A agent: #{card.description} (skill: #{skill_id})"
      skill -> "#{card.name} - #{skill.description}"
    end
  end

  @impl Normandy.Tool
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

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{input: %{"message" => message_text}}) do
    message = Message.new(:user, [Part.text(message_text)])

    opts =
      tool.transport_opts
      |> Keyword.merge(if(tool.auth_token, do: [auth_token: tool.auth_token], else: []))
      |> put_trace_headers()

    case Client.send_message(tool.endpoint, message, opts) do
      {:ok, %Claudio.A2A.Task{} = task} ->
        if Claudio.A2A.Task.terminal?(task),
          do: extract_task_result(task),
          else: poll_for_result(tool.endpoint, task.id, opts, :infinity)

      {:ok, %Claudio.A2A.Message{} = response_msg} ->
        {:ok, Enum.map_join(response_msg.parts, "\n", fn part -> Map.get(part, :text, "") end)}

      {:error, reason} ->
        {:error, "A2A request failed: #{inspect(reason)}"}
    end
  end
end
