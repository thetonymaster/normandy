defmodule Normandy.Components.Message do
  @moduledoc """
  Represents a single message in agent conversation history.

  The `:content` field is intentionally permissive so callers can pass:

    * a plain `String.t()` (e.g. simple chat text, system prompts);
    * a single `struct()` (e.g. an I/O schema or `ToolResult`, serialized
      downstream via `Normandy.Components.BaseIOSchema`);
    * a list of content blocks (`Normandy.Components.ContentBlock.*`) for
      multimodal messages combining text, images, and documents.

  The downstream LLM adapter (e.g. `Normandy.LLM.ClaudioAdapter`) inspects
  the shape and translates it to the provider's on-the-wire format.

  The schema declares `content` as `:any` rather than a narrower union:
  `Message` is not an `io_schema`, so no JSON schema is generated for this
  field and no LLM ever consumes its type. The permissive runtime type
  pairs with the precise `@type t` above — the adapter validates on its
  way out, not here.
  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          role: String.t(),
          content: String.t() | struct() | map() | [struct() | map()],
          turn_id: String.t()
        }

  schema do
    field(:role, :string)
    field(:content, :any)
    field(:turn_id, :string)
  end
end
