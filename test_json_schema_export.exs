defmodule Address do
  use Normandy.Schema

  io_schema "Address information" do
    field(:street, :string, description: "Street address", required: true)
    field(:city, :string, description: "City name", required: true)
    field(:state, :string, description: "State or province")
    field(:country, :string, description: "Country", required: true)
    field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
  end
end

defmodule ContactInfo do
  use Normandy.Schema

  io_schema "Contact information" do
    field(:phone, :string, description: "Phone number", format: "phone")
    field(:email, :string, description: "Email address", format: "email", required: true)
  end
end

defmodule User do
  use Normandy.Schema

  io_schema "User profile with nested schemas" do
    field(:name, :string, description: "Full name", required: true, min_length: 1, max_length: 100)
    field(:age, :integer, description: "User age", minimum: 0, maximum: 150)
    field(:address, Address, description: "Primary address")
    field(:contact, ContactInfo, description: "Contact information", required: true)
    field(:previous_addresses, {:array, Address}, description: "Previous addresses")
    field(:tags, {:array, :string}, description: "User tags", min_items: 1, max_items: 10)
  end
end

schema = User.get_json_schema()
IO.puts("\n=== Nested Schema JSON Export ===")
IO.puts(Poison.encode!(schema, pretty: true))
