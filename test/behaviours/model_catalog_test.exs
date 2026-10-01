defmodule Normandy.Behaviours.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.ModelCatalog
  alias Normandy.Behaviours.ModelCatalog.ModelsAPI
  alias Normandy.LLM.ClaudioAdapter

  @opus %{
    "id" => "claude-opus-5-5",
    "type" => "model",
    "display_name" => "Claude Opus 5.5",
    "max_input_tokens" => 1_000_000,
    "max_tokens" => 128_000,
    "capabilities" => %{
      "image_input" => %{"supported" => true},
      "code_execution" => %{"supported" => false}
    }
  }

  # Req.Test, not Bypass: these tests are about decoding responses, not transport.
  # Stubs are owned by the test process, so the module stays async.
  setup do
    client =
      %Normandy.LLM.ClaudioAdapter{api_key: "k"}
      |> ClaudioAdapter.to_claudio_client()
      |> Req.merge(plug: {Req.Test, __MODULE__}, retry: false)

    {:ok, opts: [client: client]}
  end

  defp respond(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  test "context_window/2 is the Models API max_input_tokens", %{opts: opts} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert String.ends_with?(conn.request_path, "/models/claude-opus-5-5")
      Req.Test.json(conn, @opus)
    end)

    assert ModelsAPI.context_window("claude-opus-5-5", opts) == {:ok, 1_000_000}
  end

  test "a response without max_input_tokens is an error", %{opts: opts} do
    respond(200, Map.delete(%{@opus | "id" => "old-model"}, "max_input_tokens"))

    assert ModelsAPI.context_window("old-model", opts) ==
             {:error, {:no_context_window, "old-model"}}
  end

  test "an unknown model (404) is an error tuple", %{opts: opts} do
    respond(404, %{
      "type" => "error",
      "error" => %{"type" => "not_found_error", "message" => "model: nope"}
    })

    assert {:error, %Claudio.APIError{}} = ModelsAPI.context_window("nope", opts)
  end

  test "an auth failure (401) is an error tuple", %{opts: opts} do
    respond(401, %{
      "type" => "error",
      "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
    })

    assert {:error, %Claudio.APIError{}} = ModelsAPI.context_window("claude-opus-5-5", opts)
  end

  test "no client is an error, not a crash" do
    assert ModelsAPI.context_window("claude-opus-5-5", []) == {:error, :no_client}
  end

  test "implements the ModelCatalog behaviour, whose only callback is context_window/2" do
    behaviours = ModelsAPI.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.ModelCatalog in behaviours
    assert ModelCatalog.behaviour_info(:callbacks) == [context_window: 2]
  end

  describe "deprecated Static stub" do
    # Resolved at runtime with safe_concat (existing atoms only): a compiled atom
    # literal here would make config_template_test's [:safe] decode test vacuous.
    setup do
      {:ok, static: Module.safe_concat(Normandy.Behaviours.ModelCatalog, "Static")}
    end

    test "context_window/2 delegates to ModelsAPI", %{opts: opts, static: static} do
      respond(200, @opus)
      assert static.context_window("claude-opus-5-5", opts) == {:ok, 1_000_000}
    end

    test "the static table is gone", %{static: static} do
      Code.ensure_loaded!(static)
      refute function_exported?(static, :limits, 0)
    end
  end
end
