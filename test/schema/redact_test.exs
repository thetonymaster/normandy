defmodule Normandy.Schema.RedactTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.BaseIOSchema
  alias Normandy.Validate

  defmodule Login do
    use Normandy.Schema

    io_schema "login" do
      field(:name, :string, description: "user name")
      field(:password, :string, description: "password", redact: true)
    end
  end

  defmodule Address do
    use Normandy.Schema

    io_schema "address" do
      field(:street, :string, description: "street")
      field(:pin, :string, description: "door pin", redact: true)
    end
  end

  defmodule Person do
    use Normandy.Schema

    io_schema "person" do
      field(:name, :string, description: "name")
      field(:home, Address, description: "home")
      field(:others, {:array, Address}, description: "other addresses")
    end
  end

  defmodule DerivedLogin do
    use Normandy.Schema
    @derive {Jason.Encoder, only: [:name, :password]}

    io_schema "login with a derived encoder" do
      field(:name, :string, description: "user name")
      field(:password, :string, description: "password", redact: true)
    end
  end

  defmodule DerivedAll do
    use Normandy.Schema
    @derive Jason.Encoder

    io_schema "every field derived" do
      field(:name, :string, description: "user name")
      field(:home, Address, description: "home")
    end
  end

  @secret "hunter2-secret"

  test "nested schemas lose their redacted fields too" do
    person = %Person{
      name: "ana",
      home: %Address{street: "Main", pin: @secret},
      others: [%Address{street: "Side", pin: @secret}]
    }

    json = BaseIOSchema.to_json(person)

    refute json =~ @secret
    refute json =~ "__meta__"

    assert Jason.decode!(json) == %{
             "name" => "ana",
             "home" => %{"street" => "Main"},
             "others" => [%{"street" => "Side"}]
           }
  end

  describe "redact: true keeps the value out of every serialization" do
    test "to_json, which is what the model sees" do
      json = BaseIOSchema.to_json(%Login{name: "ana", password: @secret})

      assert Jason.decode!(json) == %{"name" => "ana"}
    end

    test "a derived encoder that names a redacted field gets null, never the value" do
      json = BaseIOSchema.to_json(%DerivedLogin{name: "ana", password: @secret})

      assert Jason.decode!(json) == %{"name" => "ana", "password" => nil}
    end

    test "a bare @derive still hides nested redacted fields" do
      json =
        BaseIOSchema.to_json(%DerivedAll{
          name: "ana",
          home: %Address{street: "Main", pin: @secret}
        })

      assert Jason.decode!(json) == %{
               "name" => "ana",
               "home" => %{"street" => "Main"}
             }
    end
  end

  test "an invalid changeset's exception message does not print the redacted value" do
    error =
      assert_raise Normandy.InvalidChangesetError, fn ->
        %Login{}
        |> Validate.cast(%{"password" => @secret}, [:name, :password])
        |> Validate.validate_required([:name])
        |> Validate.apply_action!(:insert)
      end

    message = Exception.message(error)
    refute message =~ @secret
    assert message =~ "name"
  end
end
