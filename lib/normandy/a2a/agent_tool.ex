defmodule Normandy.A2A.AgentTool do
  @moduledoc """
  Wraps a remote A2A agent as a `Normandy.Tool`.

  When the LLM calls this tool, a message is sent to the remote agent
  via the A2A protocol and the result is returned.

  ## Example

      alias Normandy.A2A.AgentTool

      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")

      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          prefix: "research",
          auth_token: "bearer-token"
        )

      # The model sees the tool as "research__<the card's name>".
      agent = BaseAgent.register_tool(agent, tool, timeout: 60_000)

  The tool polls a remote task until it ends; the registration `:timeout` (default
  `Normandy.Tools.Executor.default_timeout/0`, 30 s) bounds the whole call, so give a
  remote agent that works for minutes a longer one.

  ## Tool names

  The tool's name is `prefix <> "__" <> card name` (plus `"__" <> skill id` for a skill),
  the card name and skill id lowercased with every run of other characters turned into one
  `_`. The remote agent chooses its card, so `:prefix` is required, with the same rule as
  `Normandy.MCP.ToolWrapper`'s (see "Tool names and policy rules" there): a policy rule
  such as `"research__*"` then matches exactly this remote's tools. `prefix: "a2a"` gives
  the names Normandy 1.x used; `prefix: false` gives the bare card name.

  ## Trust

  A remote agent is outside your trust boundary. Its card's name, description and skill
  descriptions are sent to the model as this tool's name and description, and its replies
  become the model's input: each is a prompt-injection channel that Normandy passes through
  unchanged. Register remotes you trust, and gate this tool with a policy when its replies
  can lead the model to act.
  """

  use Normandy.Tool

  alias Claudio.A2A.Client
  alias Claudio.A2A.Message
  alias Claudio.A2A.Part
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Tools.Context

  @type t :: %__MODULE__{
          endpoint: String.t(),
          agent_card: Claudio.A2A.AgentCard.t(),
          prefix: String.t() | false,
          skill_id: String.t() | nil,
          auth_token: String.t() | nil,
          poll_interval: pos_integer(),
          transport_opts: keyword()
        }

  @derive {Inspect, except: [:auth_token]}
  @enforce_keys [:endpoint, :agent_card, :prefix]
  defstruct [
    :endpoint,
    :agent_card,
    :prefix,
    :skill_id,
    :auth_token,
    poll_interval: 1_000,
    transport_opts: []
  ]

  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: {:custom, Normandy.MCP.ToolWrapper, :validate_prefix, []},
                       type_doc: "`t:String.t/0` or `false`",
                       required: true,
                       doc:
                         "The remote's namespace: the tool is named `prefix__card_name`. " <>
                           "The rule of `Normandy.MCP.ToolWrapper.new/4`'s `:prefix`; " <>
                           "`\"a2a\"` gives 1.x's names, `false` the bare card name."
                     ],
                     skill_id: [
                       type: :string,
                       doc: "The skill to expose (default: general access to the agent)."
                     ],
                     auth_token: [
                       type: :string,
                       type_doc: "`t:String.t/0`",
                       doc: "A bearer token for the remote agent."
                     ],
                     poll_interval: [
                       type: :pos_integer,
                       default: 1_000,
                       doc:
                         "Milliseconds between status requests while the remote's task is " <>
                           "not finished. The call's timeout is the only bound on the wait."
                     ],
                     transport_opts: [
                       type: :keyword_list,
                       default: [],
                       type_doc: "`t:keyword/0`",
                       doc:
                         "Options for the A2A transport. Its `:headers` (`[{name, value}]`) " <>
                           "are sent on every request; with OpenTelemetry loaded and a span " <>
                           "active, W3C `traceparent`/`tracestate` headers are added beside them " <>
                           "(a same-named header you set is kept)."
                     ]
                   )

  @doc false
  def __opts_schema__(:new), do: @new_opts_schema

  @doc """
  Creates a new AgentTool for a remote A2A agent.

  ## Options

  #{Options.docs(@new_opts_schema)}

  The call's timeout is a registration option:
  `BaseAgent.register_tool(agent, tool, timeout: ms)`. Passing `:timeout` here raises
  `ArgumentError`.
  """
  @spec new(String.t(), Claudio.A2A.AgentCard.t(), keyword() | map()) :: t()
  def new(endpoint, agent_card, opts \\ []) do
    if timeout_given?(opts) do
      raise ArgumentError,
            "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
              "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end

    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 3})

    %__MODULE__{
      endpoint: endpoint,
      agent_card: agent_card,
      prefix: Keyword.fetch!(opts, :prefix),
      skill_id: Keyword.get(opts, :skill_id),
      auth_token: Keyword.get(opts, :auth_token),
      poll_interval: Keyword.fetch!(opts, :poll_interval),
      transport_opts: Keyword.fetch!(opts, :transport_opts)
    }
  end

  # Before Options.validate!/3, so :timeout gets its own message; opts that are neither a
  # keyword list nor a map are left to Options.validate!/3 to reject.
  defp timeout_given?(opts) when is_map(opts), do: Map.has_key?(opts, :timeout)
  defp timeout_given?(opts) when is_list(opts), do: List.keymember?(opts, :timeout, 0)
  defp timeout_given?(_opts), do: false

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
  # Asks for the task until it is terminal, `poll_interval` ms apart. The executor's
  # timeout (run/2) is the only bound on the wait.
  def poll_for_result(endpoint, task_id, opts, poll_interval) do
    case Client.get_task(endpoint, task_id, opts) do
      {:ok, task} ->
        if Claudio.A2A.Task.terminal?(task) do
          extract_task_result(task)
        else
          Process.sleep(poll_interval)
          poll_for_result(endpoint, task_id, opts, poll_interval)
        end

      {:error, reason} ->
        {:error, "Failed to get task status: #{Describe.reason_tag(reason)}"}
    end
  end

  @doc false
  def extract_task_result(%{status: %{state: :completed}, artifacts: [artifact | _]}),
    do: {:ok, parts_text(artifact.parts)}

  def extract_task_result(%{status: %{state: :completed, message: %{parts: parts}}})
      when is_list(parts),
      do: {:ok, parts_text(parts)}

  def extract_task_result(%{status: %{state: :completed}}), do: {:ok, "Task completed"}

  def extract_task_result(%{status: %{state: state, message: %{parts: parts}}})
      when state in [:failed, :rejected] and is_list(parts),
      do: {:error, parts_text(parts)}

  def extract_task_result(%{status: %{state: state, message: _}})
      when state in [:failed, :rejected],
      do: {:error, "Task #{state}"}

  def extract_task_result(%{status: %{state: state}}) do
    {:error, "Task ended in unexpected state: #{state}"}
  end

  defp parts_text(parts), do: Enum.map_join(parts, "\n", &Map.get(&1, :text, ""))

  @impl Normandy.Tool
  def name(%__MODULE__{prefix: prefix} = tool), do: prefixed(prefix, base_name(tool))

  defp base_name(%__MODULE__{agent_card: card, skill_id: nil}), do: sanitize_name(card.name)

  defp base_name(%__MODULE__{agent_card: card, skill_id: skill_id}),
    do: "#{sanitize_name(card.name)}__#{sanitize_name(skill_id)}"

  defp prefixed(false, name), do: name
  defp prefixed(prefix, name) when is_binary(prefix), do: prefix <> "__" <> name

  # The card is the remote side's own text: it is quoted as the agent's self-description,
  # cut to @max_card_text characters, never presented as an instruction of this agent's.
  @max_card_text 1_000

  @impl Normandy.Tool
  def description(%__MODULE__{agent_card: card, skill_id: nil}),
    do:
      "Sends a message to the remote agent #{card.name} and returns its reply." <>
        self_description(card.description)

  def description(%__MODULE__{agent_card: card, skill_id: skill_id}) do
    lead =
      "Sends a message to the remote agent #{card.name} (skill #{skill_id}) and returns its reply."

    case Enum.find(card.skills, fn s -> s.id == skill_id end) do
      nil -> lead <> self_description(card.description)
      skill -> lead <> self_description(skill.description)
    end
  end

  defp self_description(text) when is_binary(text) and text != "" do
    quoted =
      if String.length(text) > @max_card_text,
        do: String.slice(text, 0, @max_card_text) <> "...",
        else: text

    " It describes itself as: " <> quoted
  end

  defp self_description(_text), do: ""

  @impl Normandy.Tool
  def input_schema(%__MODULE__{agent_card: card}) do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" =>
            "Message to send to #{card.name}. It cannot see this conversation, " <>
              "so include every detail it needs."
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
          else: poll_for_result(tool.endpoint, task.id, opts, tool.poll_interval)

      {:ok, %Claudio.A2A.Message{} = response_msg} ->
        {:ok, parts_text(response_msg.parts)}

      {:error, reason} ->
        # The reason's tag only: a transport error can carry the body the remote sent.
        {:error, "A2A request failed: #{Describe.reason_tag(reason)}"}
    end
  end
end
