defmodule Normandy.OptionsCoverageTest do
  use ExUnit.Case, async: true

  alias Normandy.A2A.AgentTool
  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Coordination.{ParallelOrchestrator, SequentialOrchestrator}
  alias Normandy.Resilience.Retry
  alias Normandy.Test.StubClient
  alias Normandy.Tools.{Executor, Memory, Toolset}

  # Ruling 6 (plan-wave-3.md): every lib/ file that reads `Keyword.get(opts` is either a
  # file whose public entry points validate their options with Normandy.Options.validate!/3
  # (@validated) or a file whose reads are not entry-point options (@internal, with the
  # reason). A new file fails the first test until it joins one of the two lists.
  # What this guarantees is narrow: it matches that text only (reads written as
  # `Keyword.fetch!`, `Keyword.get_lazy` or `opts[:x]` are not seen), and the lists are per
  # file, so a new entry point in a listed file is not checked. The tests below that call
  # entry points are what check validation itself.
  @pattern "Keyword.get(opts"

  @validated [
    "lib/normandy/a2a/agent_tool.ex",
    "lib/normandy/a2a/registry.ex",
    "lib/normandy/a2a/server.ex",
    "lib/normandy/agents/base_agent.ex",
    "lib/normandy/agents/base_agent/init_options.ex",
    "lib/normandy/agents/turn.ex",
    "lib/normandy/agents/turn/resume_reaper.ex",
    "lib/normandy/agents/turn/server.ex",
    "lib/normandy/agents/turn/session.ex",
    "lib/normandy/agents/turn/supervisor.ex",
    "lib/normandy/agents/turn/supervisor/horde.ex",
    "lib/normandy/batch/processor.ex",
    "lib/normandy/behaviours/agent_template.ex",
    "lib/normandy/behaviours/compactor/window_manager.ex",
    "lib/normandy/behaviours/memory_store/ets.ex",
    "lib/normandy/behaviours/memory_store/in_memory.ex",
    "lib/normandy/behaviours/memory_store/mnesia.ex",
    "lib/normandy/behaviours/memory_store/redis.ex",
    "lib/normandy/behaviours/session_registry/horde.ex",
    "lib/normandy/behaviours/session_registry/native.ex",
    "lib/normandy/behaviours/session_registry/redis.ex",
    "lib/normandy/behaviours/session_store/ets.ex",
    "lib/normandy/behaviours/session_store/in_memory.ex",
    "lib/normandy/behaviours/session_store/mnesia.ex",
    "lib/normandy/behaviours/session_store/redis.ex",
    "lib/normandy/cluster.ex",
    "lib/normandy/components/agent_memory.ex",
    "lib/normandy/context/summarizer.ex",
    "lib/normandy/context/window_manager.ex",
    "lib/normandy/coordination/agent_message.ex",
    "lib/normandy/coordination/agent_pool.ex",
    "lib/normandy/coordination/agent_process.ex",
    "lib/normandy/coordination/agent_supervisor.ex",
    "lib/normandy/coordination/hierarchical_coordinator.ex",
    "lib/normandy/coordination/parallel_orchestrator.ex",
    "lib/normandy/coordination/pattern.ex",
    "lib/normandy/coordination/reactive.ex",
    "lib/normandy/coordination/sequential_orchestrator.ex",
    "lib/normandy/coordination/stateful_context.ex",
    "lib/normandy/dsl/agent.ex",
    "lib/normandy/dsl/workflow.ex",
    "lib/normandy/mcp/registry.ex",
    "lib/normandy/mcp/tool_wrapper.ex",
    "lib/normandy/resilience/circuit_breaker.ex",
    "lib/normandy/test/fake_client.ex",
    "lib/normandy/tools/executor.ex",
    "lib/normandy/tools/toolset.ex"
  ]

  @internal %{
    "lib/normandy/coordination/agent_process/engine/server.ex" =>
      "reads the opts AgentProcess.start_link/1 already validated, to build the Turn.Session",
    "lib/normandy/behaviours/hooks.ex" =>
      "validate_entries!/2's :load comes from BaseAgent.init/1 and Turn.Server; each hook " <>
        "entry's :on_error is checked by validate_on_error!/2",
    "lib/normandy/guardrails.ex" =>
      "a guard entry's own :on_error, checked when the agent is built",
    "lib/normandy/guardrails/builtins/forbidden_substrings.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/max_length.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/regex_guard.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/semantic_scope.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/violation_error.ex" => "Exception.exception/1 fields",
    "lib/normandy/schema/validation_error.ex" => "Exception.exception/1 fields",
    "lib/normandy/llm/claudio_adapter.ex" =>
      "per-call options Normandy builds for the Model protocol (:request_kind, " <>
        ":request_tracker, :json_retries); client options are checked by validate_options!/1",
    "lib/normandy/llm/openai_compatible_adapter.ex" =>
      "per-call options Normandy builds for the Model protocol; client options are checked " <>
        "by validate_options!/1",
    "lib/normandy/llm/json_deserializer.ex" =>
      "parsing options built by Normandy's adapters (:adapter, :max_retries, :on_retry_usage)",
    "lib/normandy/llm/json/decoder.ex" => "parsing options built by JsonDeserializer",
    "lib/normandy/llm/structured_outputs.ex" =>
      "reads :structured_outputs from client.options, checked by the adapter's validate_options!/1",
    "lib/normandy/schema.ex" => "field/3 macro options, read at compile time",
    "lib/normandy/tool.ex" =>
      "`use Normandy.Tool` options, read at compile time after check_option_keys!/2 (Task 3.4b)",
    "lib/normandy/validate.ex" => "Ecto-style per-validation options (:message, ...)",
    "lib/normandy/telemetry/metadata.ex" => "telemetry metadata builder called by Normandy",
    "lib/normandy/telemetry/provider.ex" => "telemetry metadata builder called by Normandy"
  }

  defp lib_files_reading_opts do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ @pattern))
    |> Enum.sort()
  end

  describe "Ruling 6 allowlist" do
    test "every lib file that reads Keyword.get(opts is validated or allowlisted" do
      unknown = lib_files_reading_opts() -- (@validated ++ Map.keys(@internal))

      assert unknown == [], """
      These files read `#{@pattern}` but are in neither list:

      #{Enum.join(unknown, "\n")}

      If the file has a public function that takes options, validate them with
      Normandy.Options.validate!/3 and add the file to @validated; otherwise add it to
      @internal with the reason its reads are not entry-point options.
      """
    end

    test "every @validated file calls Normandy.Options.validate!/3" do
      missing =
        Enum.reject(@validated, &(File.exists?(&1) and File.read!(&1) =~ "Options.validate!("))

      assert missing == [],
             "listed in @validated but never call Options.validate!/3: #{inspect(missing)}"
    end

    test "every @internal file still reads Keyword.get(opts" do
      stale =
        Enum.reject(Map.keys(@internal), &(File.exists?(&1) and File.read!(&1) =~ @pattern))

      assert stale == [], "remove from @internal: #{inspect(stale)}"
    end
  end

  # Deferred from Task 3.1a: Normandy.Options hides the value of a sensitive key and shows the
  # option's :type_doc instead, falling back to inspect(type) when it has none. This walks
  # every option spec written in lib/ as a `key: [type: ...]` literal (composed schemas are
  # checked where such literals are written) and requires a :type_doc on every option whose
  # key is in Normandy.Options.sensitive_keys/0, and on every option nested under one. A spec
  # built at compile time (Keyword.merge/put, a computed list) is not a literal and is missed.
  describe "sensitive options" do
    test "every option whose key is sensitive has a :type_doc" do
      sensitive = Normandy.Options.sensitive_keys()

      missing =
        for file <- Enum.sort(Path.wildcard("lib/**/*.ex")),
            key <- specs_missing_type_doc(file, sensitive),
            do: "#{file}: #{inspect(key)}"

      assert missing == [], """
      These sensitive options have no :type_doc, so an invalid value's message would show
      inspect(type) instead of a readable type:

      #{Enum.join(missing, "\n")}
      """
    end
  end

  defp specs_missing_type_doc(file, sensitive) do
    {_ast, acc} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {key, spec} = node, acc when is_atom(key) and is_list(spec) ->
          if key in sensitive and option_spec?(spec),
            do: {node, missing_type_doc(key, spec, acc)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp option_spec?(spec), do: Keyword.keyword?(spec) and Keyword.has_key?(spec, :type)

  # A spec under a sensitive key, and every spec nested under it in :keys, needs a :type_doc.
  defp missing_type_doc(key, spec, acc) do
    acc = if Keyword.has_key?(spec, :type_doc), do: acc, else: [key | acc]

    case Keyword.get(spec, :keys) do
      nested when is_list(nested) -> Enum.reduce(nested, acc, &nested_missing_type_doc/2)
      _ -> acc
    end
  end

  defp nested_missing_type_doc({key, spec}, acc) when is_atom(key) and is_list(spec),
    do: if(option_spec?(spec), do: missing_type_doc(key, spec, acc), else: acc)

  defp nested_missing_type_doc(_entry, acc), do: acc

  # Entry points validated before Tasks 3.7a–3.7d: BaseAgent.init/1, run/3 and DSL new/1 (3.1),
  # Toolset.register/3, the Executor options and AgentTool.new/3's :timeout (3.4),
  # Turn.Session.new/1 and the orchestrators (3.5); Tools.Memory.new/1 and Retry keep their own.
  describe "entry points validated elsewhere still reject a misspelled key" do
    defmodule ProbeAgent do
      use Normandy.DSL.Agent

      agent do
        model("m")
      end
    end

    test "BaseAgent.init/1 (Task 3.1)" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(model: "m", client: %StubClient{}, max_tokns: 10)
        end

      assert error.message =~ ~r/^Normandy\.Agents\.BaseAgent\.init\/1: /
      assert error.message =~ ":max_tokns"
    end

    test "BaseAgent.run/3 (Task 3.1)" do
      agent = BaseAgent.init(model: "m", client: %StubClient{})
      error = assert_raise ArgumentError, fn -> BaseAgent.run(agent, "hi", timout: 1) end
      assert error.message =~ ~r/^Normandy\.Agents\.BaseAgent\.run\/3: /
      assert error.message =~ ":timout"
    end

    test "Turn.Session.new/1 (Task 3.5)" do
      error = assert_raise ArgumentError, fn -> Turn.Session.new(sesion_id: "s") end
      assert error.message =~ ~r/^Normandy\.Agents\.Turn\.Session\.new\/1: /
      assert error.message =~ ":sesion_id"
    end

    test "the orchestrators (Task 3.5b/3.5c)" do
      calls = [
        {"Normandy.Coordination.ParallelOrchestrator.execute/3",
         fn -> ParallelOrchestrator.execute([], "go", max_concurency: 2) end},
        {"Normandy.Coordination.HierarchicalCoordinator.execute/3",
         fn ->
           ParallelOrchestrator.execute_specs(
             [],
             [max_concurency: 2],
             {Normandy.Coordination.HierarchicalCoordinator, :execute, 3}
           )
         end},
        {"Normandy.Coordination.SequentialOrchestrator.execute/3",
         fn -> SequentialOrchestrator.execute([], "go", max_concurency: 2) end},
        {"Normandy.Coordination.SequentialOrchestrator.execute_with_messages/3",
         fn -> SequentialOrchestrator.execute_with_messages([], nil, max_concurency: 2) end}
      ]

      for {label, call} <- calls do
        error = assert_raise ArgumentError, call
        assert String.starts_with?(error.message, label <> ": "), "#{label}: #{error.message}"
        assert error.message =~ ":max_concurency"
      end
    end

    test "Tools.Executor.execute_tool/2 and execute_tool_classified/2 (Task 3.4c)" do
      tool = Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()})

      for fun <- [:execute_tool, :execute_tool_classified] do
        error = assert_raise ArgumentError, fn -> apply(Executor, fun, [tool, [timout: 1]]) end
        assert error.message =~ ~r/^Normandy\.Tools\.Executor\.#{fun}\/2: /
        assert error.message =~ ":timout"
      end
    end

    test "A2A.AgentTool.new/3's :timeout check (Task 3.4c)" do
      assert_raise ArgumentError,
                   "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; " <>
                     "pass it to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3",
                   fn -> AgentTool.new("http://a", nil, timeout: 1) end
    end

    test "Toolset.register/3 (Task 3.4)" do
      tool = Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()})

      error =
        assert_raise ArgumentError, fn -> Toolset.register(Toolset.new([]), tool, timeot: 1) end

      assert error.message =~ ~r/^Normandy\.Tools\.Toolset\.register\/3: /
      assert error.message =~ ":timeot"
    end

    test "Tools.Memory.new/1 (its own check)" do
      error =
        assert_raise ArgumentError, fn ->
          Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()}, max_view_char: 1)
        end

      assert error.message =~ ~r/^Normandy\.Tools\.Memory\.new\/1: /
      assert error.message =~ ":max_view_char"
    end

    test "Retry.with_retry/2 (its own check)" do
      error =
        assert_raise ArgumentError, fn -> Retry.with_retry(fn -> {:ok, 1} end, max_attemps: 2) end

      assert error.message =~ ~r/^Retry\.with_retry\/2: /
      assert error.message =~ ":max_attemps"
    end

    test "a DSL agent's generated new/1 (Task 3.1c: BaseAgent.init/1's schema under MyAgent.new/1)" do
      error =
        assert_raise ArgumentError, fn ->
          ProbeAgent.new(client: %StubClient{}, temprature: 0.1)
        end

      assert error.message =~ "#{inspect(ProbeAgent)}.new/1: "
      assert error.message =~ ":temprature"
    end
  end
end
