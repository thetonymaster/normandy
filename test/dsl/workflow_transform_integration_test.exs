defmodule Normandy.DSL.WorkflowTransformIntegrationTest do
  @moduledoc """
  Workflows that use `transform` and `when_result`, compiled through the DSL and
  run end to end with a client that reports what each agent receives.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent

  defmodule EchoClient do
    @moduledoc false
    use Normandy.Schema

    schema do
      field(:test_pid, :any)
      field(:name, :string)
      field(:reply, :string, default: "ok")
    end

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.test_pid, {:agent_input, client.name, List.last(request.messages).content})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: client.reply}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defmodule FirstAgent do
  end

  defmodule SecondAgent do
  end

  defmodule TransformWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :first do
        agent(FirstAgent)
        input("raw")
        transform(fn text -> "first got " <> text end)
      end

      step :second do
        agent(SecondAgent)
        input(from: :first)
        transform(fn %{chat_message: msg} -> "second got " <> msg end)
      end
    end
  end

  defmodule WhenWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :check do
        agent(FirstAgent)
        input("go")

        when_result do
          {:ok, %{chat_message: "broken"}} -> {:error, :rejected}
          {:ok, %{chat_message: "good"}} -> :approve
          {:ok, %{chat_message: msg}} -> {:ok, "rewritten " <> msg}
        end
      end

      step :after do
        agent(SecondAgent)
        input(from: :check)
      end
    end
  end

  defp agents(first_reply \\ "ok") do
    %{
      FirstAgent => agent("first", first_reply),
      SecondAgent => agent("second", "ok")
    }
  end

  defp agent(name, reply) do
    BaseAgent.init(%{
      client: %EchoClient{test_pid: self(), name: name, reply: reply},
      model: "test-model"
    })
  end

  test "a transform applies to a literal input and to a from: input" do
    assert {:ok, _} = TransformWorkflow.execute(agents: agents(), initial_input: "x")

    assert_receive {:agent_input, "first", first}
    assert first =~ "first got raw"

    assert_receive {:agent_input, "second", second}
    assert second =~ "second got ok"
  end

  test "steps/0 reports which steps have a transform" do
    assert [%{name: :first, transform: true}, %{name: :second, transform: true}] =
             TransformWorkflow.steps()
  end

  test "when_result {:ok, value} makes value the step result" do
    assert {:ok, results} = WhenWorkflow.execute(agents: agents("fine"), initial_input: "x")

    assert results.check == "rewritten fine"
    assert_receive {:agent_input, "second", second}
    assert second =~ "rewritten fine"
  end

  test "any other when_result value becomes the step result as it is" do
    assert {:ok, results} = WhenWorkflow.execute(agents: agents("good"), initial_input: "x")

    assert results.check == :approve
    assert_receive {:agent_input, "second", second}
    assert second =~ "approve"
  end

  test "when_result {:error, reason} fails the workflow at that step" do
    assert {:error, {:check, :rejected}} =
             WhenWorkflow.execute(agents: agents("broken"), initial_input: "x")

    refute_received {:agent_input, "second", _}
  end

  test "an agent that raises fails the workflow at that step instead of crashing it" do
    failing =
      BaseAgent.init(%{
        client: %Normandy.Test.TaggingClient{name: "first", fail_on: "raw"},
        model: "test-model"
      })

    assert {:error, {:first, %RuntimeError{message: "first failed"}}} =
             TransformWorkflow.execute(
               agents: %{agents() | FirstAgent => failing},
               initial_input: "x"
             )
  end

  test "steps/0 reports which steps have a when_result" do
    assert [%{name: :check, condition: true}, %{name: :after, condition: false}] =
             WhenWorkflow.steps()
  end

  describe "compile-time validation" do
    defp compile(body) do
      Code.compile_string("""
      defmodule Normandy.DSL.WorkflowTransformIntegrationTest.Bad#{System.unique_integer([:positive])} do
        use Normandy.DSL.Workflow
        workflow do
          #{body}
        end
      end
      """)
    end

    test "from: an unknown step is rejected" do
      assert_raise ArgumentError,
                   ~r/step :b takes input from :nope, which is not an earlier step/,
                   fn ->
                     compile("""
                     step :b do
                       agent(Foo)
                       input(from: :nope)
                     end
                     """)
                   end
    end

    test "a step without an agent is rejected" do
      assert_raise ArgumentError, ~r/step :a has no agent/, fn ->
        compile("""
        step :a do
          input("x")
        end
        """)
      end
    end

    test "a duplicate step name is rejected" do
      assert_raise ArgumentError, ~r/step :a is defined more than once/, fn ->
        compile("""
        step :a do
          agent(Foo)
        end
        step :a do
          agent(Foo)
        end
        """)
      end
    end
  end
end
