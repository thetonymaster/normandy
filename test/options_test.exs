defmodule Normandy.OptionsTest do
  use ExUnit.Case, async: true

  alias Normandy.Options

  @mfa {Normandy.Agents.BaseAgent, :init, 1}

  @schema NimbleOptions.new!(
            model: [type: :string, required: true, doc: "The model."],
            count: [type: :pos_integer, default: 3, doc: "A count."],
            client: [type: {:struct, URI}, type_doc: "a `URI` struct", doc: "A client."],
            transport: [
              type: :keyword_list,
              default: [],
              keys: [
                headers: [type: :keyword_list, type_doc: "a keyword list", doc: "Headers."],
                pool: [type: :pos_integer, default: 1, doc: "Pool size."]
              ],
              doc: "Transport."
            ]
          )

  describe "validate!/3" do
    test "returns a keyword list with the defaults filled in" do
      assert Options.validate!([model: "m"], @schema, @mfa) |> Enum.sort() ==
               [count: 3, model: "m", transport: [pool: 1]]
    end

    test "accepts a map with atom keys and returns a keyword list" do
      validated = Options.validate!(%{model: "m", count: 5}, @schema, @mfa)

      assert Keyword.keyword?(validated)
      assert Keyword.fetch!(validated, :count) == 5
    end

    test "an unknown option is named, with the supported ones" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :modle; supported: " <>
                     ":model, :count, :client, :transport",
                   fn -> Options.validate!([model: "m", modle: "x"], @schema, @mfa) end
    end

    test "several unknown options are named together" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown options [:a, :b]; supported: " <>
                     ":model, :count, :client, :transport",
                   fn -> Options.validate!([model: "m", a: 1, b: 2], @schema, @mfa) end
    end

    test "an unknown nested option names its parent and the parent's options" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :poool in :transport; " <>
                     "supported: :headers, :pool",
                   fn -> Options.validate!([model: "m", transport: [poool: 2]], @schema, @mfa) end
    end

    test "an unknown option to a schema with no options says it takes none" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :name; it takes no options",
                   fn -> Options.validate!([name: "x"], NimbleOptions.new!([]), @mfa) end
    end

    test "an unknown option's value is never shown" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([model: "m", api_kye: "sk-ant-canary"], @schema, @mfa)
        end

      assert error.message =~ ":api_kye"
      refute error.message =~ "sk-ant-canary"
    end

    test "a bad value of an ordinary option keeps NimbleOptions' message" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: invalid value for :count option: " <>
                     "expected positive integer, got: 0",
                   fn -> Options.validate!([model: "m", count: 0], @schema, @mfa) end
    end

    test "a missing required option is named" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: required :model option not found, " <>
                     "received options: [:count]",
                   fn -> Options.validate!([count: 1], @schema, @mfa) end
    end

    test "a sensitive option's bad value is not shown; its type_doc is" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([model: "m", client: "sk-ant-canary"], @schema, @mfa)
        end

      assert error.message ==
               "Normandy.Agents.BaseAgent.init/1: invalid value for :client option: expected " <>
                 "a `URI` struct; the value is not shown because :client can hold a secret"
    end

    test "a sensitive option nested under another is not shown either" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!(
            [model: "m", transport: [headers: "Bearer sk-ant-canary"]],
            @schema,
            @mfa
          )
        end

      assert error.message =~ ":headers option in :transport"
      refute error.message =~ "sk-ant-canary"
    end

    test "a container value of an ordinary option is described by type, not shown" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!(
            [model: "m", transport: %{headers: [authorization: "sk-canary"]}],
            @schema,
            @mfa
          )
        end

      assert error.message ==
               "Normandy.Agents.BaseAgent.init/1: invalid value for :transport option: " <>
                 "expected keyword list, got: a map"

      refute error.message =~ "sk-canary"
    end

    test "a list that is not a keyword list is rejected by position" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a list whose element 1 is an integer",
                   fn -> Options.validate!([{:model, "m"}, 2], @schema, @mfa) end
    end

    test "a struct is not an options map" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a %URI{} struct",
                   fn -> Options.validate!(%URI{}, @schema, @mfa) end
    end

    test "string keys are rejected, naming them" do
      assert_raise ArgumentError,
                   ~s(Normandy.Agents.BaseAgent.init/1: option names must be atoms, got: ["model"]),
                   fn -> Options.validate!(%{"model" => "m"}, @schema, @mfa) end
    end

    test "a value that is neither a list nor a map is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a string (2 bytes)",
                   fn -> Options.validate!("hi", @schema, @mfa) end
    end

    test "a duplicated option is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: option :model given more than once",
                   fn -> Options.validate!([model: "a", model: "b"], @schema, @mfa) end
    end

    test "the prefix names any module, function and arity" do
      assert_raise ArgumentError, ~r/^Normandy.Agents.Turn.Server.start_link\/1: /, fn ->
        Options.validate!([x: 1], @schema, {Normandy.Agents.Turn.Server, :start_link, 1})
      end
    end
  end

  test "docs/1 is NimbleOptions' option list" do
    assert Options.docs(@schema) == NimbleOptions.docs(@schema)
    assert Options.docs(@schema) =~ "* `:model` (`t:String.t/0`) - Required. The model."
  end

  test "sensitive_keys/0 names the credential-carrying options" do
    assert :client in Options.sensitive_keys()
    assert :api_key in Options.sensitive_keys()
    assert :mcp_servers in Options.sensitive_keys()
  end

  test "plain_map/1 accepts a plain map and names the type of anything else" do
    assert {:ok, %{a: 1}} = Options.plain_map(%{a: 1})

    assert {:error, "expected a plain map (not a struct), got: a %URI{}"} =
             Options.plain_map(%URI{})

    assert {:error, "expected a plain map (not a struct), got: a list"} = Options.plain_map(a: 1)

    assert {:error, "expected a plain map (not a struct), got: a string (4 bytes)"} =
             Options.plain_map("acme")
  end

  describe "redact_container/2" do
    test "no string inside a container survives, at any depth" do
      value = %{"sk-key" => [1 | "sk-tail"], a: ["sk-x", {1, "sk-y"}]}
      message = "bad: " <> inspect(value) <> " / " <> inspect("sk-x") <> " / " <> inspect("sk-y")

      redacted = Options.redact_container(message, value)

      refute redacted =~ "sk-"
      assert redacted =~ "a string (4 bytes)"
    end

    test "a top-level string keeps the message; an empty string inside is described only via its container" do
      assert Options.redact_container("got: \"abc\"", "abc") == "got: \"abc\""

      assert Options.redact_container(~s(got: "" and [""]), [""]) ==
               ~s(got: "" and a list)
    end
  end
end
