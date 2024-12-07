defmodule Normandy.Schemas.SystemPromptSpecification do
  use TypedStruct

  typedstruct do
    @typedoc "A System Prompt Specification"

    field(:backgroud, list(), default: [])
    field(:steps, list(), default: [])
    field(:output_instructions, list(), default: [])
    field(:additional_information, list(), default: [])
  end
end
