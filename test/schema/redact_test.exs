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

  @secret "hunter2-secret"

  describe "redact: true keeps the value out of every serialization" do
    test "to_json, which is what the model sees" do
      json = BaseIOSchema.to_json(%Login{name: "ana", password: @secret})

      assert Poison.decode!(json) == %{"name" => "ana"}
    end

    test "__str__ and __rich__" do
      login = %Login{name: "ana", password: @secret}

      refute BaseIOSchema.__str__(login) =~ @secret
      refute BaseIOSchema.__rich__(login) =~ @secret
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
