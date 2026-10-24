defmodule Normandy.Security.LowFindingsTest do
  # The security LOW findings closed in Task 5.7d, one describe each (security.md).
  use ExUnit.Case, async: true

  alias Claudio.A2A.AgentCard
  alias Normandy.A2A.AgentTool
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn.{Server, Session}
  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory, as: SessionInMemory
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Guardrails.Builtins.SemanticScope
  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Tool
  alias Normandy.Tools.{Context, Executor, Memory}

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(mod)
    String.replace(doc, ~r/\s+/, " ")
  end

  defp doc(mod, fun, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    Enum.find_value(docs, fn
      {{:function, ^fun, ^arity}, _, _, %{"en" => text}, _} -> String.replace(text, ~r/\s+/, " ")
      _ -> nil
    end)
  end

  describe "SEC-10: remote tools are documented as untrusted" do
    test "ToolWrapper, MCP.Registry and AgentTool say so" do
      assert moduledoc(ToolWrapper) =~ "## Trust"
      assert moduledoc(ToolWrapper) =~ "prompt-injection channel"
      assert moduledoc(AgentTool) =~ "## Trust"
      assert moduledoc(AgentTool) =~ "prompt-injection channel"
      assert moduledoc(Normandy.MCP.Registry) =~ "reaches the model unchanged"
    end
  end

  describe "SEC-11: error text names a reason's tag, never its terms" do
    defmodule BodyAdapter do
      @moduledoc false
      def call_tool(_client, _name, _args, _opts),
        do: {:error, {:unexpected_response, %{body: "SECRET-BODY"}}}
    end

    test "an MCP transport error" do
      wrapper =
        ToolWrapper.new(BodyAdapter, nil, %Claudio.MCP.Client.Tool{name: "t"}, prefix: false)

      assert Tool.run(wrapper, %Context{tool_call_id: "c", input: %{}}) ==
               {:error, "MCP tool 't' failed: :unexpected_response"}
    end

    test "an A2A transport error" do
      card = AgentCard.new("remote", "r")

      tool =
        AgentTool.new("http://127.0.0.1:1/a2a", card,
          prefix: "a2a",
          transport_opts: [transport: __MODULE__.FailingTransport]
        )

      assert Tool.run(tool, %Context{tool_call_id: "c", input: %{"message" => "hi"}}) ==
               {:error, "A2A request failed: :unexpected_response"}
    end

    defmodule FailingTransport do
      @moduledoc false
      def send_message(_endpoint, _message, _opts),
        do: {:error, {:unexpected_response, "SECRET-BODY"}}
    end

    defmodule RaisingTool do
      @moduledoc false
      use Normandy.Tool, name: "raising", description: "raises"
      defstruct [:fun]
      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}
      @impl Normandy.Tool
      def run(%__MODULE__{fun: fun}, _context), do: fun.()
    end

    defp run_raising(fun) do
      Executor.execute_tool(%RaisingTool{fun: fun},
        context: %Context{tool_call_id: "c", input: %{}}
      )
    end

    test "a KeyError names its key, never the map it searched" do
      assert run_raising(fn ->
               Map.fetch!(Function.identity(%{token: "SECRET-TOKEN"}), :missing)
             end) ==
               {:error, "Tool execution failed: KeyError: key :missing not found"}
    end

    test "an exception that inspects its term is named by module" do
      assert run_raising(fn -> {:ok, _} = Function.identity({:error, %{token: "SECRET"}}) end) ==
               {:error, "Tool execution failed: MatchError"}

      assert run_raising(fn -> Enum.count(Function.identity({:token, "SECRET"})) end) ==
               {:error, "Tool execution failed: Protocol.UndefinedError"}
    end

    test "an Erlang error is named by its reason's tag, never its terms" do
      assert run_raising(fn -> :erlang.error(Function.identity({:boom, "SECRET"})) end) ==
               {:error, "Tool execution failed: ErlangError: :boom"}
    end

    test "other exceptions keep their message" do
      assert run_raising(fn -> raise ArgumentError, "bad level" end) ==
               {:error, "Tool execution failed: bad level"}
    end
  end

  describe "SEC-12: client inspect hides credential-bearing options" do
    test "req_options and headers are redacted on both adapters, api_key is left out" do
      options = %{
        req_options: [auth: {:bearer, "SECRET-AUTH"}],
        headers: [{"x-key", "SECRET-H"}],
        thinking: :adaptive
      }

      for client <- [
            %ClaudioAdapter{api_key: "SECRET-KEY", options: options},
            %OpenAICompatibleAdapter{api_key: "SECRET-KEY", options: options}
          ] do
        text = inspect(client)
        refute text =~ "SECRET"
        refute text =~ "api_key"
        assert text =~ ~s(req_options: "**redacted**")
        assert text =~ ~s(headers: "**redacted**")
        assert text =~ "thinking: :adaptive"
      end
    end

    # Decision 23 (B8): the userinfo, query and fragment of a base_url, as the shared
    # breaker's key leaves them out.
    test "a base_url prints without its userinfo, query or fragment" do
      url = "https://user:SECRET-PW@llm.example.com:8443/v1?key=SECRET-Q#SECRET-F"

      for client <- [
            %ClaudioAdapter{api_key: "k", base_url: url},
            %OpenAICompatibleAdapter{api_key: "k", base_url: url},
            %ClaudioAdapter{api_key: "k", options: %{base_url: url}}
          ] do
        text = inspect(client)
        refute text =~ "SECRET"
        refute text =~ "user:"
        assert text =~ ~s("https://llm.example.com:8443/v1")
      end

      assert inspect(%ClaudioAdapter{api_key: "k", base_url: "user:SECRET-PW@nohost"}) =~
               ~s(base_url: "**redacted**")
    end
  end

  describe "SEC-13: a session id cannot change the Redis hash tag" do
    defp session_opts(sid) do
      [
        session_id: sid,
        registry: {Native, nil},
        supervisor: self(),
        store: {SessionInMemory, nil},
        config: %BaseAgentConfig{}
      ]
    end

    test "an id with { or }, or an empty one, is refused" do
      for sid <- ["}x", "a{b", "a}b", ""] do
        assert_raise ArgumentError,
                     ~r/Turn.Session.new\/1: invalid value for :session_id option/,
                     fn ->
                       Session.new(session_opts(sid))
                     end
      end

      assert %Session{session_id: "user-42"} = Session.new(session_opts("user-42"))
    end

    # Decision 23 (B12): the refused id is described by type, never echoed.
    test "the error names the id's type, not the id" do
      error = assert_raise ArgumentError, fn -> Session.new(session_opts("SECRET-ID{x}")) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a string (12 bytes)"
    end

    test "AgentProcess under :server applies the rule to agent_id, other engines do not" do
      for id <- ["a{b", ""] do
        error =
          assert_raise ArgumentError, fn ->
            AgentProcess.start_link(
              agent: %BaseAgentConfig{},
              agent_id: id,
              turn_engine: :server
            )
          end

        assert error.message =~ "Normandy.Coordination.AgentProcess.start_link/1: invalid value"
        assert error.message =~ ":agent_id"
        refute error.message =~ "a{b"
      end

      assert {:ok, pid} =
               AgentProcess.start_link(agent: %BaseAgentConfig{}, agent_id: "a{b")

      assert AgentProcess.agent_id_of(pid) == {:ok, "a{b"}
    end

    test "Turn.Server.start_link/1 takes the same type" do
      assert_raise ArgumentError,
                   ~r/Turn.Server.start_link\/1: invalid value for :session_id option/,
                   fn ->
                     Server.start_link(
                       session_id: "}x",
                       store: {SessionInMemory, nil},
                       registry: {Native, nil}
                     )
                   end
    end
  end

  # Decision 23 (B12): a wrong-shaped host return is described by type, never echoed.
  describe "SemanticScope: a wrong-shaped return is described by type" do
    test "the fast_path's and the classifier's return values are not in the message" do
      fast_path = [classifier: fn _v, _c -> :allow end, fast_path: fn _v, _c -> "SECRET-1" end]
      error = assert_raise ArgumentError, fn -> SemanticScope.check("q", fast_path) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a string (8 bytes)"

      classifier = [classifier: fn _v, _c -> {:block, "SECRET-2"} end]
      error = assert_raise ArgumentError, fn -> SemanticScope.check("q", classifier) end
      refute error.message =~ "SECRET"
      assert error.message =~ "got: a tuple"
    end
  end

  describe "SEC-15 and SEC-17: documented limits" do
    test "an approved call runs whatever tool now holds the name" do
      assert doc(Normandy.Agents.Dispatch, :execute_approved, 3) =~
               "the approved call runs whatever tool now holds the name"
    end

    test "Executor says it applies no controls" do
      assert moduledoc(Executor) =~ "## No controls"
      assert moduledoc(Executor) =~ "no policy, no approval, no hooks, no budget"
    end
  end

  describe "SEC-16: max_view_chars is a hard cap" do
    test "a single 100 KB line views in at most max_view_chars plus the note" do
      store = InMemory.new()

      {:ok, _} =
        InMemory.put(store, "ns", "/memories/big.md", String.duplicate("é", 100_000), :new)

      tool = Memory.new(store: {InMemory, store}, max_view_chars: 1_000)

      assert {:ok, text} =
               Memory.run(tool, %Context{
                 tool_call_id: "c",
                 values: %{memory_namespace: "ns"},
                 input: %{"command" => "view", "path" => "/memories/big.md"}
               })

      [header, body, note] = String.split(text, "\n")
      assert header == "Here's the content of /memories/big.md with line numbers:"
      assert String.length(body) == 1_000
      assert String.valid?(body)

      assert note ==
               "[truncated inside line 1 of 1: it is longer than the 1000-character view limit]"
    end

    test "a long first line followed by more lines points at the next one" do
      store = InMemory.new()
      content = String.duplicate("x", 50) <> "\nsecond\n"
      {:ok, _} = InMemory.put(store, "ns", "/memories/two.md", content, :new)
      tool = Memory.new(store: {InMemory, store}, max_view_chars: 20)

      assert {:ok, text} =
               Memory.run(tool, %Context{
                 tool_call_id: "c",
                 values: %{memory_namespace: "ns"},
                 input: %{"command" => "view", "path" => "/memories/two.md"}
               })

      assert text =~
               "\n[truncated inside line 1 of 2: it is longer than the 20-character view " <>
                 "limit; use view_range [2, -1] to read on]"
    end
  end

  describe "SEC-18: NUL in memory content is refused on every backend" do
    test "create, str_replace and insert refuse NUL with :invalid_input" do
      store = InMemory.new()
      tool = Memory.new(store: {InMemory, store})

      ctx = fn input ->
        %Context{tool_call_id: "c", values: %{memory_namespace: "ns"}, input: input}
      end

      assert Memory.run(
               tool,
               ctx.(%{"command" => "create", "path" => "/memories/a", "file_text" => "a\0b"})
             ) ==
               {:error, "Error: `file_text` must not contain NUL characters"}

      {:ok, _} =
        Memory.run(
          tool,
          ctx.(%{"command" => "create", "path" => "/memories/a", "file_text" => "ab"})
        )

      assert Memory.run(
               tool,
               ctx.(%{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "a",
                 "new_str" => "\0"
               })
             ) ==
               {:error, "Error: `new_str` must not contain NUL characters"}

      assert Memory.run(
               tool,
               ctx.(%{
                 "command" => "insert",
                 "path" => "/memories/a",
                 "insert_line" => 0,
                 "insert_text" => "\0"
               })
             ) ==
               {:error, "Error: `insert_text` must not contain NUL characters"}

      assert {:ok, %{content: "ab"}} = InMemory.get(store, "ns", "/memories/a")
    end
  end
end
