defmodule Normandy.Agents.BaseAgent.Prompt do
  @moduledoc false
  # What a call sends besides its history: the system prompt (as the Request fields
  # `system`, `output_schema_prompt` and `context_prompt`), the tool definitions, and
  # their estimate for the compactor. Pure: reads the config and the call's response
  # model only. BaseAgent.Handlers builds every request with it.

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Context.TokenEstimate
  alias Normandy.Context.WindowManager
  alias Normandy.LLM.Request
  alias Normandy.Schema.Wire
  alias Normandy.Tools.Toolset

  # The response model a call is made with: the caller's, else the output schema. A
  # streamed turn's state holds the `:streamed_message` marker (Handlers); its requests
  # show the tool-loop one (Handlers.build_stream_request/1).
  @spec call_model(struct() | :streamed_message | nil, map()) :: struct() | nil
  def call_model(:streamed_message, _config), do: %ToolCallResponse{}
  def call_model(nil, config), do: Map.get(config, :output_schema)
  def call_model(response_model, _config), do: response_model

  # The tool definitions a call sends.
  @spec tool_schemas(map()) :: [map()]
  def tool_schemas(config) do
    if BaseAgent.has_tools?(config), do: Toolset.to_tool_schemas(config.toolset), else: []
  end

  # The part of a request that is not history (AX-12): its system prompt and tool
  # definitions, estimated like the history.
  @spec estimate(map(), struct() | nil) :: non_neg_integer()
  def estimate(config, response_model),
    do: estimate_parts(parts(config, response_model), tool_schemas(config))

  # estimate/2 of prompt parts and tool schemas already built for a request.
  @spec estimate_parts(map(), [map()]) :: non_neg_integer()
  def estimate_parts(parts, tool_schemas) do
    TokenEstimate.estimate_tokens(Request.system_prompt(parts)) +
      TokenEstimate.estimate_tokens(Normandy.JSON.encode!(tool_schemas))
  end

  # The whole request a call sent, from the parts and tool schemas that built it (a
  # context provider's text can change from call to call) and the memory's cached entry
  # estimates: what Compactor.WindowManager compares, stamped on a tool-loop response
  # beside the size the provider counted (ToolCallResponse.estimated_input_tokens, AX-12).
  @spec estimate_request(map(), [map()], map()) :: non_neg_integer()
  def estimate_request(parts, tool_schemas, memory),
    do: estimate_parts(parts, tool_schemas) + WindowManager.estimate_conversation_tokens(memory)

  # The system prompt every call sends, as the Request fields `system`,
  # `output_schema_prompt` and `context_prompt`: the prompt specification's static
  # sections and the input schema; the output schema `response_model` shows
  # (shown_schema/2), which an adapter that constrains the answer to it leaves out
  # (AX-19); and last the context providers' section, which can change from call to call
  # (AX-20).
  @spec parts(map(), struct() | nil) :: %{
          system: String.t(),
          output_schema_prompt: String.t() | nil,
          context_prompt: String.t() | nil
        }
  def parts(config, response_model) do
    {static, context_prompt} = SystemPromptGenerator.generate_parts(config.prompt_specification)
    system = with_input_schema(static, config.input_schema)

    output =
      schema_section(
        "OUTPUT SCHEMA",
        "Respond with a JSON object that matches this schema, using exactly these field names and no others:",
        shown_schema(response_model, config)
      )

    %{system: system, output_schema_prompt: output, context_prompt: context_prompt}
  end

  # The output schema the final answer's text must match, for an adapter that can
  # constrain it (Request.output_format): the schema the system prompt shows on a
  # tool-loop call or a stream, never the chat schema (its answer is plain text). A
  # call whose response model is the output schema itself needs none.
  @spec output_format(struct() | nil, map()) :: struct() | nil
  def output_format(%ToolCallResponse{} = loop, config), do: shown_schema(loop, config)
  def output_format(_response_model, _config), do: nil

  # The schema the system prompt shows. ToolCallResponse is the adapter's internal
  # shape for a tool-loop reply; tool calls travel through the API's `tools` parameter.
  # Showing its schema made models write that shape as their text answer, which then
  # landed verbatim in chat_message. A tool loop's final text is parsed into a custom
  # output schema (Handlers.convert_turn_output/3), so the model is told that schema
  # instead; a chat_message schema takes the text as is and shows none.
  defp shown_schema(%ToolCallResponse{}, %{output_schema: %{chat_message: _}}), do: nil
  defp shown_schema(%ToolCallResponse{}, %{output_schema: schema}), do: schema
  defp shown_schema(response_model, _config), do: response_model

  # A custom input schema reaches the model as the user message's JSON, so the system
  # prompt describes its fields (AX-29). The default schema's one chat_message is sent
  # as plain text and needs none.
  defp with_input_schema(system_prompt, %BaseAgentInputSchema{}), do: system_prompt

  defp with_input_schema(system_prompt, input_schema) do
    section =
      schema_section(
        "INPUT SCHEMA",
        "Each new user input is a JSON object that matches this schema (tool results are not):",
        input_schema
      )

    Request.system_prompt(%{
      system: system_prompt,
      output_schema_prompt: section,
      context_prompt: nil
    })
  end

  # A schema struct's JSON Schema under `heading`, or nil for a struct with no schema (or
  # nil); an encoding failure raises rather than silently sending the prompt without its
  # schema.
  defp schema_section(_heading, _intro, nil), do: nil

  defp schema_section(heading, intro, schema_struct) do
    case Normandy.Schema.json_schema(schema_struct) do
      nil ->
        nil

      schema ->
        schema_json = Normandy.JSON.encode!(Wire.encodable(schema), pretty: true)
        "# #{heading}\n#{intro}\n```json\n#{schema_json}\n```"
    end
  end
end
