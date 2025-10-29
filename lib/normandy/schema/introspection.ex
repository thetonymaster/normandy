defmodule Normandy.Schema.Introspection do
  @moduledoc """
  Utilities for introspecting Normandy schemas at runtime.

  This module provides functions to query schema metadata, including:
  - Field definitions and types
  - Required fields
  - Constraints and validations
  - Virtual and computed fields
  - JSON Schema specifications

  ## Examples

      defmodule User do
        use Normandy.Schema

        schema do
          field(:id, :integer, required: true)
          field(:name, :string, required: true, min_length: 3)
          field(:email, :string, format: "email")
          field(:age, :integer, minimum: 0)
        end
      end

      # List all field names
      Introspection.list_fields(User)
      #=> [:id, :name, :email, :age]

      # Get required fields
      Introspection.get_required_fields(User)
      #=> [:id, :name]

      # Get field type
      Introspection.get_field_type(User, :name)
      #=> :string

      # Get field constraints
      Introspection.get_field_constraints(User, :name)
      #=> %{min_length: 3, required: true}

      # Check if field is virtual
      Introspection.virtual_field?(User, :name)
      #=> false
  """

  @doc """
  Lists all field names defined in the schema.

  ## Examples

      iex> Introspection.list_fields(User)
      [:id, :name, :email, :age]
  """
  @spec list_fields(module()) :: [atom()]
  def list_fields(schema_module) when is_atom(schema_module) do
    schema_module.__schema__(:fields)
  end

  @doc """
  Returns a list of all required fields.

  ## Examples

      iex> Introspection.get_required_fields(User)
      [:id, :name]
  """
  @spec get_required_fields(module()) :: [atom()]
  def get_required_fields(schema_module) when is_atom(schema_module) do
    spec = schema_module.__schema__(:specification)

    case spec[:required] do
      nil -> []
      required when is_list(required) -> required
    end
  end

  @doc """
  Returns the type of a specific field.

  Returns `nil` if the field does not exist.

  ## Examples

      iex> Introspection.get_field_type(User, :name)
      :string

      iex> Introspection.get_field_type(User, :nonexistent)
      nil
  """
  @spec get_field_type(module(), atom()) :: atom() | {atom(), any()} | nil
  def get_field_type(schema_module, field_name)
      when is_atom(schema_module) and is_atom(field_name) do
    schema_module.__schema__(:type, field_name)
  end

  @doc """
  Returns all constraints defined for a specific field.

  Constraints include: required, min_length, max_length, pattern, format,
  minimum, maximum, min_items, max_items, unique_items, enum, etc.

  Returns an empty map if the field has no constraints.

  ## Examples

      iex> Introspection.get_field_constraints(User, :name)
      %{required: true, min_length: 3}

      iex> Introspection.get_field_constraints(User, :email)
      %{format: "email"}
  """
  @spec get_field_constraints(module(), atom()) :: map()
  def get_field_constraints(schema_module, field_name)
      when is_atom(schema_module) and is_atom(field_name) do
    spec = schema_module.__schema__(:specification)
    properties = spec[:properties] || %{}
    field_spec = properties[field_name] || %{}
    required_fields = spec[:required] || []

    constraints = %{}

    # Check if field is required
    constraints =
      if field_name in required_fields do
        Map.put(constraints, :required, true)
      else
        constraints
      end

    # Add string constraints
    constraints =
      constraints
      |> maybe_add_constraint(:min_length, field_spec[:minLength])
      |> maybe_add_constraint(:max_length, field_spec[:maxLength])
      |> maybe_add_constraint(:pattern, field_spec[:pattern])
      |> maybe_add_constraint(:format, field_spec[:format])

    # Add number constraints
    constraints =
      constraints
      |> maybe_add_constraint(:minimum, field_spec[:minimum])
      |> maybe_add_constraint(:maximum, field_spec[:maximum])
      |> maybe_add_constraint(:exclusive_minimum, field_spec[:exclusiveMinimum])
      |> maybe_add_constraint(:exclusive_maximum, field_spec[:exclusiveMaximum])

    # Add array constraints
    constraints =
      constraints
      |> maybe_add_constraint(:min_items, field_spec[:minItems])
      |> maybe_add_constraint(:max_items, field_spec[:maxItems])
      |> maybe_add_constraint(:unique_items, field_spec[:uniqueItems])

    # Add enum constraint
    maybe_add_constraint(constraints, :enum, field_spec[:enum])
  end

  defp maybe_add_constraint(constraints, _key, nil), do: constraints
  defp maybe_add_constraint(constraints, key, value), do: Map.put(constraints, key, value)

  @doc """
  Checks if a field is virtual (excluded from JSON schema).

  Virtual fields exist in the struct but may not be included in the
  JSON Schema representation unless explicitly configured.

  ## Examples

      iex> Introspection.virtual_field?(User, :computed_field)
      true

      iex> Introspection.virtual_field?(User, :name)
      false
  """
  @spec virtual_field?(module(), atom()) :: boolean()
  def virtual_field?(schema_module, field_name)
      when is_atom(schema_module) and is_atom(field_name) do
    spec = schema_module.__schema__(:specification)
    properties = spec[:properties] || %{}

    # A field is considered virtual if it exists in the schema but not in properties
    field_exists? = field_name in schema_module.__schema__(:fields)
    in_properties? = Map.has_key?(properties, field_name)

    field_exists? and not in_properties?
  end

  @doc """
  Returns the complete JSON Schema specification for the schema.

  ## Examples

      iex> Introspection.get_specification(User)
      %{
        type: :object,
        properties: %{...},
        required: [:id, :name]
      }
  """
  @spec get_specification(module()) :: map()
  def get_specification(schema_module) when is_atom(schema_module) do
    schema_module.__schema__(:specification)
  end

  @doc """
  Returns the description of the schema if defined.

  Returns `nil` if no description is set.

  ## Examples

      iex> Introspection.get_description(User)
      "User account information"
  """
  @spec get_description(module()) :: String.t() | nil
  def get_description(schema_module) when is_atom(schema_module) do
    spec = schema_module.__schema__(:specification)
    spec[:description]
  end

  @doc """
  Returns metadata about a specific field including type, constraints, and description.

  This is a convenience function that combines information from multiple
  introspection functions.

  ## Examples

      iex> Introspection.get_field_metadata(User, :name)
      %{
        type: :string,
        required: true,
        constraints: %{min_length: 3},
        virtual: false,
        description: "User's full name"
      }
  """
  @spec get_field_metadata(module(), atom()) :: map() | nil
  def get_field_metadata(schema_module, field_name)
      when is_atom(schema_module) and is_atom(field_name) do
    if field_name in list_fields(schema_module) do
      spec = schema_module.__schema__(:specification)
      properties = spec[:properties] || %{}
      field_spec = properties[field_name] || %{}

      %{
        type: get_field_type(schema_module, field_name),
        required: field_name in get_required_fields(schema_module),
        constraints: get_field_constraints(schema_module, field_name),
        virtual: virtual_field?(schema_module, field_name),
        description: field_spec[:description]
      }
    else
      nil
    end
  end

  @doc """
  Returns a list of all fields with their complete metadata.

  ## Examples

      iex> Introspection.list_all_metadata(User)
      %{
        id: %{type: :integer, required: true, ...},
        name: %{type: :string, required: true, ...},
        email: %{type: :string, required: false, ...},
        age: %{type: :integer, required: false, ...}
      }
  """
  @spec list_all_metadata(module()) :: %{atom() => map()}
  def list_all_metadata(schema_module) when is_atom(schema_module) do
    schema_module
    |> list_fields()
    |> Enum.map(fn field_name ->
      {field_name, get_field_metadata(schema_module, field_name)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Checks if a schema has composition constraints (anyOf, oneOf, allOf).

  Checks both the schema root level and individual field properties.

  ## Examples

      iex> Introspection.has_composition?(User)
      false

      iex> Introspection.has_composition?(PolymorphicSchema)
      true
  """
  @spec has_composition?(module()) :: boolean()
  def has_composition?(schema_module) when is_atom(schema_module) do
    spec = schema_module.__schema__(:specification)

    # Check root level
    root_has_composition? =
      Map.has_key?(spec, :anyOf) or Map.has_key?(spec, :oneOf) or Map.has_key?(spec, :allOf)

    # Check field properties
    properties = spec[:properties] || %{}

    field_has_composition? =
      properties
      |> Map.values()
      |> Enum.any?(fn field_spec ->
        Map.has_key?(field_spec, :anyOf) or Map.has_key?(field_spec, :oneOf) or
          Map.has_key?(field_spec, :allOf)
      end)

    root_has_composition? or field_has_composition?
  end

  @doc """
  Checks if a schema has conditional constraints (if/then/else).

  Checks both the schema root level and individual field properties.

  ## Examples

      iex> Introspection.has_conditionals?(User)
      false

      iex> Introspection.has_conditionals?(ConditionalSchema)
      true
  """
  @spec has_conditionals?(module()) :: boolean()
  def has_conditionals?(schema_module) when is_atom(schema_module) do
    spec = schema_module.__schema__(:specification)

    # Check root level
    root_has_conditionals? = Map.has_key?(spec, :if)

    # Check field properties
    properties = spec[:properties] || %{}

    field_has_conditionals? =
      properties
      |> Map.values()
      |> Enum.any?(fn field_spec -> Map.has_key?(field_spec, :if) end)

    root_has_conditionals? or field_has_conditionals?
  end
end
