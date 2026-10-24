defmodule Normandy.Agents.ContextPromptCacheTest do
  @moduledoc """
  AX-20: the context providers' section, whose text can change from call to call, is the
  last part of the system prompt. `ClaudioAdapter` sends it as a system block of its own
  after the cached one, so a change leaves the rest of the system prompt cached.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.LLM.Request
  alias Normandy.Test.FakeClient
  alias Normandy.Test.WireScript

  defmodule Clock do
    @moduledoc false
    defstruct [:now]

    defimpl Normandy.Components.ContextProvider do
      def title(_clock), do: "Now"
      def get_info(%{now: now}), do: now
    end
  end

  defp spec(now),
    do: %PromptSpecification{
      background: ["You plan meetings."],
      steps: ["Check the calendar."],
      context_providers: %{clock: %Clock{now: now}}
    }

  defp text(text), do: %{"type" => "text", "text" => text}

  test "generate_parts/1 splits the static sections from the Context section" do
    assert {static, context} = SystemPromptGenerator.generate_parts(spec("09:00"))
    assert static == "# Role\n- You plan meetings.\n# How to work\n- Check the calendar."
    assert context =~ ~r/\A# Context\n.*\n## Now\n09:00\z/s
    assert SystemPromptGenerator.generate_prompt(spec("09:00")) == static <> "\n" <> context

    assert {_static, nil} =
             SystemPromptGenerator.generate_parts(%PromptSpecification{background: ["x"]})
  end

  test "a request carries the context apart, and system_prompt/1 puts it last" do
    client = FakeClient.new([{:text, "ok"}])
    config = BaseAgent.init(%{client: client, model: "m", prompt_specification: spec("09:00")})
    assert {:ok, _config, _answer} = BaseAgent.run(config, "plan")

    assert [request] = FakeClient.requests(client)
    refute request.system =~ "# Context"
    assert request.context_prompt =~ "## Now\n09:00"
    assert String.ends_with?(Request.system_prompt(request), request.context_prompt)
  end

  test "on the wire the cached block stays the same when the context changes" do
    client =
      WireScript.client([{:json, [text("ok")], "end_turn"}, {:json, [text("ok")], "end_turn"}])

    for now <- ["09:00", "09:05"] do
      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-opus-5-5",
          prompt_specification: spec(now)
        })

      assert {:ok, _config, _answer} = BaseAgent.run(config, "plan")
    end

    assert_receive {:wire_body, 0, %{"system" => [cached_a, context_a]}}
    assert_receive {:wire_body, 1, %{"system" => [cached_b, context_b]}}

    assert cached_a == cached_b
    assert %{"cache_control" => %{"type" => "ephemeral"}} = cached_a
    refute Map.has_key?(context_a, "cache_control")
    assert context_a["text"] =~ "09:00"
    assert context_b["text"] =~ "09:05"
  end
end
