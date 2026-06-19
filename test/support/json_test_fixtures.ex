defmodule Normandy.LLM.Json.TestFixtures do
  @moduledoc false

  defmodule MultiField do
    @moduledoc false
    use Normandy.Schema

    io_schema "multi-field schema for wrapper tests" do
      field(:chat_message, :string, description: "message")
      field(:count, :integer, description: "count", default: 0)
    end
  end

  defmodule RequiredField do
    @moduledoc false
    use Normandy.Schema

    io_schema "schema with a required field" do
      field(:chat_message, :string, description: "required message", required: true)
    end
  end

  defmodule RecoveryFixture do
    @moduledoc false
    use Normandy.Schema

    io_schema "fixture for truncated-string recovery tests" do
      field(:page_text, :string, description: "transcribed text", default: "")
      field(:facts, {:array, :string}, description: "facts", default: [])
    end
  end
end
