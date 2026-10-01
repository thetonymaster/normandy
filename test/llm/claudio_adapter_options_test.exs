defmodule Normandy.LLM.ClaudioAdapterOptionsTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.LLM.ClaudioAdapter

  defp apply_opts(options, call_opts \\ []),
    do: ClaudioAdapter.__apply_client_options__(Request.new("m"), options, call_opts)

  describe "absent options" do
    test "nil values behave like absent keys (all eight keys)" do
      options = %{
        thinking: nil,
        thinking_display: nil,
        thinking_budget: nil,
        effort: nil,
        speed: nil,
        inference_geo: nil,
        fallbacks: nil,
        task_budget: nil
      }

      assert apply_opts(options) == Request.new("m")
      assert apply_opts(options, stream: true, task_budget_remaining: 1_000) == Request.new("m")
    end

    test "task_budget_remaining without task_budget is ignored" do
      assert apply_opts(%{}, task_budget_remaining: 5_000) == Request.new("m")
    end
  end

  describe "thinking" do
    test ":adaptive enables adaptive thinking" do
      assert apply_opts(%{thinking: :adaptive}).thinking == %{"type" => "adaptive"}
    end

    test ":adaptive with thinking_display sets display" do
      r = apply_opts(%{thinking: :adaptive, thinking_display: :summarized})
      assert r.thinking == %{"type" => "adaptive", "display" => "summarized"}
    end

    test "thinking_display :updates declares its beta" do
      r = apply_opts(%{thinking: :adaptive, thinking_display: :updates})
      assert "thinking-display-updates-2026-08-18" in r.betas
    end

    test ":disabled turns thinking off" do
      assert apply_opts(%{thinking: :disabled}).thinking == %{"type" => "disabled"}
    end

    test "an unknown thinking value raises naming the key" do
      assert_raise ArgumentError, ~r/:thinking must be :adaptive or :disabled/, fn ->
        apply_opts(%{thinking: :on})
      end
    end

    test "thinking_budget keeps the budget_tokens shape" do
      assert apply_opts(%{thinking_budget: 2048}).thinking ==
               %{"type" => "enabled", "budget_tokens" => 2048}
    end
  end

  describe "effort, speed, inference_geo" do
    test "effort writes output_config.effort" do
      assert apply_opts(%{effort: :high}).output_config == %{"effort" => "high"}
    end

    test "speed sets speed and the fast-mode beta" do
      r = apply_opts(%{speed: :fast})
      assert r.speed == "fast"
      assert "fast-mode-2026-02-01" in r.betas
    end

    test "inference_geo sets inference_geo" do
      assert apply_opts(%{inference_geo: :us}).inference_geo == "us"
    end

    test "a bad value reaches Claudio's own ArgumentError" do
      assert_raise ArgumentError, ~r/Request.set_effort/, fn ->
        apply_opts(%{effort: :extreme})
      end
    end
  end

  describe "fallbacks" do
    test ":default" do
      r = apply_opts(%{fallbacks: :default})
      assert r.fallbacks == "default"
      assert "server-side-fallback-2026-07-01" in r.betas
    end

    test "a model list" do
      assert apply_opts(%{fallbacks: ["claude-opus-5"]}).fallbacks == [
               %{"model" => "claude-opus-5"}
             ]
    end
  end

  describe "task_budget" do
    test "total only: the server tracks the countdown" do
      r = apply_opts(%{task_budget: 64_000})
      assert r.output_config == %{"task_budget" => %{"type" => "tokens", "total" => 64_000}}
      assert "task-budgets-2026-03-13" in r.betas
    end

    test "with a per-call remaining (after in-turn compaction)" do
      r = apply_opts(%{task_budget: 64_000}, task_budget_remaining: 40_000)

      assert r.output_config == %{
               "task_budget" => %{"type" => "tokens", "total" => 64_000, "remaining" => 40_000}
             }
    end
  end

  describe "combinations Normandy rejects" do
    test "thinking with thinking_budget" do
      assert_raise ArgumentError, ~r/:thinking and :thinking_budget/, fn ->
        apply_opts(%{thinking: :adaptive, thinking_budget: 2048})
      end
    end

    test "thinking_display without thinking: :adaptive" do
      assert_raise ArgumentError, ~r/:thinking_display requires thinking: :adaptive/, fn ->
        apply_opts(%{thinking_display: :summarized})
      end

      assert_raise ArgumentError, ~r/:thinking_display requires thinking: :adaptive/, fn ->
        apply_opts(%{thinking: :disabled, thinking_display: :summarized})
      end
    end

    test "fallbacks with streaming" do
      error =
        assert_raise ArgumentError, fn -> apply_opts(%{fallbacks: :default}, stream: true) end

      assert error.message =~ "does not support :fallbacks on streaming calls"
      assert error.message =~ "stream callback"
    end
  end

  describe "output_config merge with structured outputs" do
    test "effort and task_budget survive set_output_format/2" do
      schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

      r =
        apply_opts(%{effort: :medium, task_budget: 30_000})
        |> Request.set_output_format(schema)

      assert r.output_config["effort"] == "medium"
      assert r.output_config["task_budget"]["total"] == 30_000
      assert r.output_config["format"]["schema"] == schema
    end
  end

  describe "stream_converse/7 wiring" do
    test "fallbacks with stream_converse raises before any HTTP call" do
      # A closed port: if the guard were missing, the call fails fast locally
      # instead of reaching api.anthropic.com.
      bypass = Bypass.open()
      Bypass.down(bypass)

      client = %ClaudioAdapter{
        api_key: "k",
        base_url: "http://localhost:#{bypass.port}/",
        options: %{fallbacks: :default}
      }

      assert_raise ArgumentError, ~r/does not support :fallbacks on streaming calls/, fn ->
        Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter.stream_converse(
          client,
          "m",
          nil,
          100,
          [],
          nil,
          []
        )
      end
    end
  end
end
