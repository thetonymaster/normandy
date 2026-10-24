defmodule Normandy.Tool do
  @moduledoc """
  The contract every tool implements.

  A tool is a struct whose module implements this behaviour. The struct holds the tool's
  configuration (an endpoint, a store, an index name), set by the application when it
  registers the tool (`Normandy.Tools.Toolset.register/3`). The model's input never goes into
  it: the dispatcher validates the input against `c:input_schema/1`
  (`Normandy.Tools.Input.validate/2`) and passes it to `c:run/2` as `context.input`.

  ## Callbacks

    * `c:name/1`: the name the model calls the tool by, 1 to 64 letters, digits, `_` or `-`.
    * `c:description/1`: what the tool does, for the model.
    * `c:input_schema/1`: the JSON Schema object of the input.
    * `c:run/2`: runs the tool. `context.input` is the validated input. Returns
      `{:ok, result}` or `{:error, reason}`; either reaches the model as the tool result.

  ## `use Normandy.Tool`

      defmodule MyApp.Search do
        defmodule Input do
          use Normandy.Schema

          io_schema "Search input" do
            field(:query, :string, required: true, description: "What to look for")
            field(:limit, :integer, default: 5, minimum: 1, maximum: 20)
          end
        end

        use Normandy.Tool, name: "search", description: "Searches the catalogue", input: Input

        defstruct [:index]

        @impl Normandy.Tool
        def run(%__MODULE__{index: index}, %Normandy.Tools.Context{input: %Input{} = input}),
          do: MyApp.Catalogue.search(index, input.query, input.limit)
      end

  `use Normandy.Tool` declares the behaviour, and each option generates one callback:
  `:name` → `c:name/1`, `:description` → `c:description/1`, `:input` (a module that uses
  `Normandy.Schema`, defined before the `use`) → `c:input_schema/1`. With `:input`,
  `context.input` is a struct of that schema. Leave an option out and write its callback
  when the value depends on the struct, or to hand-write the JSON Schema map; without
  `:input`, `context.input` is a string-keyed map checked against that map. Do not pass an
  option and also define its callback.

  `name/1`, `description/1`, `input_schema/1` and `run/2` on this module call the tool's own
  callbacks.
  """

  alias Normandy.Tools.Context
  alias Normandy.Tools.Toolset

  @doc """
  Returns the name the model calls the tool by, 1 to 64 letters, digits, `_` or `-`.

  `Toolset.register/3` registers the tool under it. `use Normandy.Tool, name: "..."`
  generates it.
  """
  @callback name(tool :: struct()) :: String.t()
  @doc """
  Returns what the tool does, as a string for the model.

  `use Normandy.Tool, description: "..."` generates it.
  """
  @callback description(tool :: struct()) :: String.t()
  @doc """
  Returns the JSON Schema object that describes the tool's input, or `nil` for none.

  The dispatcher validates the model's input against it before `c:run/2`; a tool that
  returns `nil` has its input rejected. `use Normandy.Tool, input: Schema` generates it from
  the schema module.
  """
  @callback input_schema(tool :: struct()) :: map() | nil
  @doc """
  Runs the tool for one call, with the validated input in `context.input`, and returns
  `{:ok, result}` or `{:error, reason}`.

  Either reaches the model as the tool result; an error is marked as an error. A return
  value of any other shape, a raise, an exit or a throw becomes an error result as well,
  and so does running past the tool's timeout.
  """
  @callback run(tool :: struct(), Context.t()) :: {:ok, term()} | {:error, term()}

  @use_options [:name, :description, :input]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Normandy.Tool

      {normandy_tool_name, normandy_tool_description, normandy_tool_input} =
        Normandy.Tool.__use_options__!(__MODULE__, opts)

      @normandy_tool_name normandy_tool_name
      @normandy_tool_description normandy_tool_description
      @normandy_tool_input normandy_tool_input

      if normandy_tool_name do
        @impl Normandy.Tool
        def name(_tool), do: @normandy_tool_name
      end

      if normandy_tool_description do
        @impl Normandy.Tool
        def description(_tool), do: @normandy_tool_description
      end

      if normandy_tool_input do
        @impl Normandy.Tool
        def input_schema(_tool), do: @normandy_tool_input.__schema__(:specification)

        @doc false
        def __tool_input__, do: @normandy_tool_input
      end
    end
  end

  @doc false
  @spec __use_options__!(module(), term()) ::
          {String.t() | nil, String.t() | nil, module() | nil}
  def __use_options__!(module, opts) do
    check_option_keys!(module, opts)

    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)
    input = Keyword.get(opts, :input)

    check!(
      module,
      is_nil(name) or Toolset.valid_name?(name),
      ":name must be 1 to 64 letters, digits, underscores or dashes, got: #{inspect(name)}"
    )

    check!(
      module,
      is_nil(description) or is_binary(description),
      ":description must be a string, got: #{inspect(description)}"
    )

    check!(
      module,
      is_nil(input) or schema_module?(input),
      ":input must be a module that uses Normandy.Schema, got: #{inspect(input)}"
    )

    {name, description, input}
  end

  defp check_option_keys!(module, opts) do
    unless Keyword.keyword?(opts),
      do: fail!(module, "expected a keyword list of options, got: #{inspect(opts)}")

    # The house style of Normandy.Options (Task 3.1a): one key bare, several as a list.
    case Keyword.keys(opts) -- @use_options do
      [] ->
        :ok

      [key] ->
        fail!(module, "unknown option #{inspect(key)}; supported: :name, :description, :input")

      unknown ->
        fail!(
          module,
          "unknown options #{inspect(unknown)}; supported: :name, :description, :input"
        )
    end
  end

  defp check!(_module, true, _message), do: :ok
  defp check!(module, false, message), do: fail!(module, message)

  @spec fail!(module(), String.t()) :: no_return()
  defp fail!(module, message),
    do: raise(ArgumentError, "use Normandy.Tool in #{inspect(module)}: " <> message)

  # Waits for a module compiled in the same project (Code.ensure_compiled/1 cooperates with
  # the parallel compiler), so the input schema may live in its own file.
  defp schema_module?(input) when is_atom(input) do
    match?({:module, ^input}, Code.ensure_compiled(input)) and
      function_exported?(input, :__schema__, 1)
  end

  defp schema_module?(_input), do: false

  @doc "The tool's name, from its module's `c:name/1`."
  @spec name(struct()) :: String.t()
  def name(%module{} = tool), do: module.name(tool)

  @doc "The tool's description, from its module's `c:description/1`."
  @spec description(struct()) :: String.t()
  def description(%module{} = tool), do: module.description(tool)

  @doc """
  The tool's input JSON Schema, from its module's `c:input_schema/1`. `nil` when the tool has
  none (an MCP tool whose server sent no schema); such a tool's input is rejected.
  """
  @spec input_schema(struct()) :: map() | nil
  def input_schema(%module{} = tool), do: module.input_schema(tool)

  @doc "Runs the tool through its module's `c:run/2`."
  @spec run(struct(), Context.t()) :: {:ok, term()} | {:error, term()}
  def run(%module{} = tool, %Context{} = context), do: module.run(tool, context)

  @doc """
  Whether `module` implements this behaviour. Loads it first, so a module this node has not
  loaded yet (interactive mode) is not taken for a non-tool.
  """
  @spec implemented_by?(atom()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in (module.module_info(:attributes)
                     |> Keyword.get_values(:behaviour)
                     |> List.flatten())
  end
end
