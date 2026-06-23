# Normandy Agent Horde Demo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `examples/agent_horde/` — a multi-agent research pipeline that fans out across 3 search engines + Firecrawl and 3 LLM providers (Claude/OpenAI/DO), synthesizes a cited report, and writes it to a local `.md` file — plus the one core-library addition it needs (`Normandy.LLM.OpenAICompatibleAdapter`) and a shot-by-shot screen-recording script.

**Architecture:** A plain-Elixir `Pipeline` orchestrates 7 stages. LLM *reasoning* steps (Planner, Curator, 3× Analyst, Editor) are real Normandy agents; *tool* steps (3× search, Firecrawl scrape) are real `Normandy.Tools.BaseTool` implementations the pipeline invokes **directly and in parallel** via `Task.async_stream` (deterministic → reliable structured data downstream). All agents return **prose** (no structured-output JSON dependence — sidesteps the JSON-leakage failure class); the pipeline parses where it needs structure (newline-split queries, regex URLs). The multi-provider beat is the Analyst stage: one `Analyst` agent module instantiated 3× with 3 different `Model` clients.

**Tech Stack:** Elixir, Normandy DSL (`DSL.Agent`, `Tools.BaseTool`, `Coordination.Reactive`), Req (HTTP), Jason/Poison (JSON), live APIs (Anthropic, OpenAI, DO-inference, Exa, SerpAPI, Serper, Firecrawl).

## Global Constraints

- **Secrets from env only**, never hardcoded, never logged: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DO_INFERENCE_KEY`, `DO_INFERENCE_URL` (=`https://inference.do-ai.run/v1`), `EXA_API_KEY`, `SERPAPI_API_KEY`, `SERPER_API_KEY`, `FIRECRAWL_API_KEY`.
- **Models:** Claude=`claude-sonnet-4-6`, OpenAI=`gpt-4o`, DO=`llama3.3-70b-instruct`.
- **No network in `mix test`.** Every test is offline (stubbed Req via the `plug:` option, or pure-function tests, or the `ModelMockup` test client). Any live test is tagged `@tag :live` and excluded by default.
- **`mix test` (core) and `examples/agent_horde` `mix test` must both pass.** Project rule: failing tests get fixed even if unrelated.
- **`mix format` before every commit**, scoped to touched files only.
- New core deps allowed: `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}` (both already transitive via Claudio; declare explicitly).
- Add files individually to git (no `git add .`). No AI attribution in commits.
- Reports land in `examples/agent_horde/reports/` (git-ignored).

## File Structure

```
lib/normandy/llm/openai_compatible_adapter.ex     # NEW core: Model protocol impl for OpenAI-compatible endpoints
test/llm/openai_compatible_adapter_test.exs        # NEW core test (offline)
mix.exs                                             # add :req, :jason to deps

examples/agent_horde/
  mix.exs
  .gitignore                                        # reports/
  .formatter.exs
  config/{config,dev}.exs
  lib/agent_horde.ex
  lib/agent_horde/application.ex                    # (optional) minimal; CLI is the entry
  lib/agent_horde/clients.ex                        # build Claude/OpenAI/DO Model clients from env
  lib/agent_horde/text.ex                           # extract prose from an agent response
  lib/agent_horde/tools/exa_search.ex
  lib/agent_horde/tools/serpapi_search.ex
  lib/agent_horde/tools/serper_search.ex
  lib/agent_horde/tools/firecrawl_scrape.ex
  lib/agent_horde/agents/{planner,curator,analyst,editor}.ex
  lib/agent_horde/pipeline.ex                       # 7-stage orchestration + Writer
  lib/agent_horde/cli.ex                            # interactive prompt + per-stage logging
  test/support/stub_tool.exs                        # offline stub tool for pipeline test
  test/agent_horde_test.exs                         # offline smoke (clients shape, text extraction, pipeline w/ stubs)
  reports/.keep

marketing/demo-1.0/agent-horde-script.md           # the screen-recording script
```

---

### Task 1: Core — `Normandy.LLM.OpenAICompatibleAdapter`

**Files:**
- Modify: `mix.exs` (root) — add `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}` to `deps/0`.
- Create: `lib/normandy/llm/openai_compatible_adapter.ex`
- Test: `test/llm/openai_compatible_adapter_test.exs`

**Interfaces:**
- Consumes: `Normandy.Agents.Model` protocol (`lib/normandy/agents/model.ex`), `Normandy.Components.Message` (fields `:role` string, `:content`), `Normandy.LLM.JsonDeserializer.deserialize_with_retry/8` (reused exactly as in `lib/normandy/llm/claudio_adapter.ex:834`).
- Produces: a struct `%Normandy.LLM.OpenAICompatibleAdapter{api_key, base_url, options, finch}` whose `Model.converse/7` returns `{populated_response_model, usage_map | nil}` (same contract as `ClaudioAdapter`).

**Reference:** mirror `lib/normandy/llm/claudio_adapter.ex` structure — `use Normandy.Schema`, `@derive {Inspect, except: [:api_key]}`, inline `defimpl Normandy.Agents.Model`, and reuse its `convert_response_to_normandy/populate_schema/populate_standard_schema` logic verbatim for structured output + prose fallback.

- [ ] **Step 1: Add deps.** In root `mix.exs` `deps/0`, add `{:req, "~> 0.5"}` and `{:jason, "~> 1.4"}`. Run `mix deps.get`. Expected: resolves (both already present transitively).

- [ ] **Step 2: Write the failing test** `test/llm/openai_compatible_adapter_test.exs`:

```elixir
defmodule Normandy.LLM.OpenAICompatibleAdapterTest do
  use ExUnit.Case, async: true
  alias Normandy.LLM.OpenAICompatibleAdapter, as: Adapter
  alias Normandy.Components.Message

  describe "convert_messages/1" do
    test "maps Normandy messages to OpenAI role/content maps" do
      msgs = [
        %Message{role: "system", content: "You are helpful."},
        %Message{role: "user", content: "Hi"}
      ]
      assert Adapter.convert_messages(msgs) == [
               %{"role" => "system", "content" => "You are helpful."},
               %{"role" => "user", "content" => "Hi"}
             ]
    end

    test "raises on non-string content (text-only v1)" do
      assert_raise ArgumentError, fn ->
        Adapter.convert_messages([%Message{role: "user", content: [%{}]}])
      end
    end
  end

  describe "extract_text/1" do
    test "pulls assistant content from a chat-completions body" do
      body = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "hello world"}}]}
      assert Adapter.extract_text(body) == "hello world"
    end

    test "returns empty string when no choices" do
      assert Adapter.extract_text(%{"choices" => []}) == ""
    end
  end

  describe "converse/7 (stubbed transport)" do
    test "returns response_model with prose in :chat_message" do
      # Stub Req via the plug option carried in options[:req_options].
      plug = fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "The answer is 42."}}],
          "usage" => %{"total_tokens" => 10}
        })
      end

      client = %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: %{req_options: [plug: plug]}
      }

      schema = %Normandy.Agents.ChatMessage{}  # default agent output schema (verify exact module in BaseAgent)
      msgs = [%Message{role: "user", content: "What is the answer?"}]

      {resp, usage} =
        Normandy.Agents.Model.converse(client, "gpt-4o", 0.7, 1024, msgs, schema, [])

      assert resp.chat_message == "The answer is 42."
      assert usage == %{"total_tokens" => 10}
    end
  end
end
```

> NOTE for implementer: confirm the default agent output schema module name (the one whose `:chat_message` field `ClaudioAdapter`'s fallback sets at `claudio_adapter.ex:850`). If `Normandy.Agents.ChatMessage` is not it, use the correct module in the test. If `Req.Test` requires a registered stub name rather than a bare function plug, adapt to the installed Req version's documented test mechanism — the intent is: no real network, body is the JSON above.

- [ ] **Step 3: Run it, watch it fail.** `mix test test/llm/openai_compatible_adapter_test.exs` → FAIL (module undefined).

- [ ] **Step 4: Implement** `lib/normandy/llm/openai_compatible_adapter.ex`:

```elixir
defmodule Normandy.LLM.OpenAICompatibleAdapter do
  @moduledoc """
  Adapter implementing `Normandy.Agents.Model` against any OpenAI-compatible
  Chat Completions endpoint (OpenAI, DigitalOcean Inference, etc.).

  Text-completion only (v1): tool/function calling is not supported and a
  non-empty `opts[:tools]` raises. Structured output + prose fallback reuse the
  same `Normandy.LLM.JsonDeserializer` path as `Normandy.LLM.ClaudioAdapter`.

      client = %Normandy.LLM.OpenAICompatibleAdapter{
        api_key: System.get_env("OPENAI_API_KEY"),
        base_url: "https://api.openai.com/v1"
      }
  """
  use Normandy.Schema

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          options: map(),
          finch: atom() | nil
        }

  @derive {Inspect, except: [:api_key]}
  schema do
    field(:api_key, :string, required: true)
    field(:base_url, :string, default: "https://api.openai.com/v1")
    field(:options, :map, default: %{})
    field(:finch, :any, default: nil)
  end

  # --- Pure helpers (public for tests) ---

  @doc false
  def convert_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %Normandy.Components.Message{role: role, content: content}
      when role in ["system", "user", "assistant"] and is_binary(content) ->
        %{"role" => role, "content" => content}

      %Normandy.Components.Message{role: role, content: content} ->
        raise ArgumentError,
              "OpenAICompatibleAdapter (text-only v1): unsupported message " <>
                "role=#{inspect(role)} / content=#{inspect(content)}"
    end)
  end

  @doc false
  def extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
      when is_binary(content),
      do: content

  def extract_text(_), do: ""

  @doc false
  def build_body(model, temperature, max_tokens, messages) do
    %{
      "model" => model,
      "messages" => convert_messages(messages),
      "temperature" => temperature,
      "max_tokens" => max_tokens
    }
  end

  defimpl Normandy.Agents.Model do
    alias Normandy.LLM.OpenAICompatibleAdapter, as: A

    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
      if Keyword.get(opts, :tools, []) != [] do
        raise ArgumentError,
              "OpenAICompatibleAdapter does not support tools (text-only v1)"
      end

      url = String.trim_trailing(client.base_url, "/") <> "/chat/completions"
      body = A.build_body(model, temperature, max_tokens, messages)

      req_options =
        [
          json: body,
          headers: [{"authorization", "Bearer " <> client.api_key}],
          receive_timeout: Map.get(client.options, :timeout, 120_000)
        ] ++ Map.get(client.options, :req_options, [])

      case Req.post(url, req_options) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          content = A.extract_text(resp_body)
          populated = populate(content, response_model, client, model, temperature, max_tokens, messages)
          {populated, Map.get(resp_body, "usage")}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          IO.warn("OpenAI-compatible API error #{status}: #{inspect(resp_body)}")
          {response_model, nil}

        {:error, error} ->
          IO.warn("OpenAI-compatible transport error: #{inspect(error)}")
          {response_model, nil}
      end
    end

    # Mirror ClaudioAdapter.convert_response_to_normandy/populate_standard_schema.
    # max_retries: 0 → prose responses fall back to :chat_message without
    # wasteful extra LLM round-trips (analysts/editor return prose).
    defp populate(content, %{__struct__: _} = schema, client, model, temperature, max_tokens, messages) do
      case Normandy.LLM.JsonDeserializer.deserialize_with_retry(
             content, schema, client, model, temperature, max_tokens, messages, max_retries: 0
           ) do
        {:ok, validated} -> validated
        {:error, _} when is_binary(content) -> Map.put(schema, :chat_message, content)
        {:error, _} -> schema
      end
    end

    defp populate(content, _non_struct, _c, _m, _t, _mt, _msgs), do: content
  end
end
```

> NOTE: verify `JsonDeserializer.deserialize_with_retry/8` accepts `max_retries: 0`; if it only accepts `max_retries >= 1` or the fallback key differs, match what `claudio_adapter.ex:832-843` passes and accept the extra retries. Verify the `:chat_message` fallback field matches the default schema used in the test.

- [ ] **Step 5: Run the test, watch it pass.** `mix test test/llm/openai_compatible_adapter_test.exs` → PASS.
- [ ] **Step 6: Full core suite.** `mix format lib/normandy/llm/openai_compatible_adapter.ex test/llm/openai_compatible_adapter_test.exs mix.exs` then `mix test`. Expected: green.
- [ ] **Step 7: Commit.** `git add mix.exs lib/normandy/llm/openai_compatible_adapter.ex test/llm/openai_compatible_adapter_test.exs && git commit -m "feat(llm): OpenAI-compatible Model adapter (OpenAI + DO inference)"`

---

### Task 2: Example app scaffold

**Files:** Create `examples/agent_horde/{mix.exs,.gitignore,.formatter.exs,config/config.exs,config/dev.exs,lib/agent_horde.ex,test/test_helper.exs,test/agent_horde_test.exs,reports/.keep}`

**Interfaces:** Produces a compiling app namespaced `AgentHorde`, with `:normandy` (path dep) + `:req` + `:jason` available and `ExUnit.configure(exclude: [:live])`.

- [ ] **Step 1:** `mix.exs`:

```elixir
defmodule AgentHorde.MixProject do
  use Mix.Project
  def project do
    [app: :agent_horde, version: "0.1.0", elixir: "~> 1.15",
     start_permanent: Mix.env() == :prod, deps: deps()]
  end
  def application, do: [extra_applications: [:logger]]
  defp deps do
    [{:normandy, path: "../../"}, {:claudio, "~> 0.5.0"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}]
  end
end
```

- [ ] **Step 2:** `config/config.exs` → `import Config` + `config :normandy, adapter: Poison` + `import_config "#{config_env()}.exs"`. `config/dev.exs` → `import Config` + `config :logger, level: :warning` (clean recording). `.gitignore` → `reports/\n!reports/.keep\n_build/\ndeps/`. `.formatter.exs` → `[inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]`. `lib/agent_horde.ex` → module stub with `@moduledoc`. `reports/.keep` empty.
- [ ] **Step 3:** `test/test_helper.exs`:

```elixir
ExUnit.configure(exclude: [:live])
ExUnit.start()
```

- [ ] **Step 4:** `test/agent_horde_test.exs` minimal:

```elixir
defmodule AgentHordeTest do
  use ExUnit.Case
  test "app module loads", do: assert Code.ensure_loaded?(AgentHorde)
end
```

- [ ] **Step 5:** `cd examples/agent_horde && mix deps.get && mix compile && mix test`. Expected: green.
- [ ] **Step 6: Commit** the created files individually with message `chore(example): scaffold agent_horde app`.

---

### Task 3: Search tools (Exa, SerpAPI, Serper)

**Files:** Create `lib/agent_horde/tools/{exa_search,serpapi_search,serper_search}.ex`; Test: add to `test/agent_horde_test.exs` (parse functions).

**Interfaces:** Each tool — `defstruct [:query, results: nil]` + `defimpl Normandy.Tools.BaseTool` with `tool_name/1`, `tool_description/1`, `input_schema/1`, `run/1`. Produces: `run(%{query: q})` → `{:ok, [%{url: , title: , snippet: }]}` | `{:error, reason}`. Each also exposes a public `parse/1` (raw decoded body → normalized list) for offline testing.

**Reference:** `examples/customer_support_app/lib/customer_support/tools/order_lookup_tool.ex` for the BaseTool shape.

- [ ] **Step 1: Write failing parse tests** (one per engine), e.g. Exa:

```elixir
test "ExaSearch.parse normalizes results" do
  body = %{"results" => [%{"url" => "https://a.com", "title" => "A", "text" => "snip"}]}
  assert AgentHorde.Tools.ExaSearch.parse(body) ==
           [%{url: "https://a.com", title: "A", snippet: "snip"}]
end
```
(SerpAPI body: `%{"organic_results" => [%{"link","title","snippet"}]}`. Serper body: `%{"organic" => [%{"link","title","snippet"}]}`.)

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** Exa example:

```elixir
defmodule AgentHorde.Tools.ExaSearch do
  defstruct [:query, results: nil]

  @num_results 5

  def parse(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn r ->
      %{url: r["url"], title: r["title"] || "", snippet: r["text"] || r["snippet"] || ""}
    end)
  end
  def parse(_), do: []

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "exa_search"
    def tool_description(_), do: "Neural web search via Exa. Returns top results with URLs and snippets."
    def input_schema(_), do: %{type: "object", properties: %{query: %{type: "string"}}, required: ["query"]}

    def run(%{query: query}) do
      case Req.post("https://api.exa.ai/search",
             json: %{query: query, numResults: 5, contents: %{text: true}},
             headers: [{"x-api-key", System.get_env("EXA_API_KEY")}],
             receive_timeout: 30_000) do
        {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
          {:ok, @for.parse(body)}
        {:ok, %Req.Response{status: s, body: b}} -> {:error, "Exa #{s}: #{inspect(b)}"}
        {:error, e} -> {:error, inspect(e)}
      end
    end
  end
end
```
SerpAPI `run`: `Req.get("https://serpapi.com/search.json", params: [q: query, api_key: System.get_env("SERPAPI_API_KEY"), num: 5])`. Serper `run`: `Req.post("https://google.serper.dev/search", json: %{q: query, num: 5}, headers: [{"x-api-key", System.get_env("SERPER_API_KEY")}])`. Each `run` returns `{:ok, @for.parse(body)}`.

> NOTE: `@for` inside `defimpl` refers to the tool struct module — `@for.parse/1` calls the public parser. Verify this resolves; if not, fully qualify (e.g. `AgentHorde.Tools.ExaSearch.parse/1`).

- [ ] **Step 4: Run parse tests → pass.**
- [ ] **Step 5: Add a `@tag :live` test per engine** that calls `BaseTool.run(%Tool{query: "elixir programming language"})` and asserts `{:ok, [_ | _]}` (excluded by default; proves the live call in Task 9).
- [ ] **Step 6:** `mix format` touched files, `mix test` (live excluded) → green. **Commit** `feat(agent_horde): Exa/SerpAPI/Serper search tools`.

---

### Task 4: Firecrawl scrape tool

**Files:** Create `lib/agent_horde/tools/firecrawl_scrape.ex`; Test in `test/agent_horde_test.exs`.

**Interfaces:** `defstruct [:url]` + BaseTool. `run(%{url: u})` → `{:ok, %{url:, title:, markdown:}}`. Public `parse/2(url, body)`.

- [ ] **Step 1: Failing parse test:**

```elixir
test "FirecrawlScrape.parse pulls markdown + title" do
  body = %{"data" => %{"markdown" => "# Hi", "metadata" => %{"title" => "Hi Page"}}}
  assert AgentHorde.Tools.FirecrawlScrape.parse("https://x.com", body) ==
           %{url: "https://x.com", title: "Hi Page", markdown: "# Hi"}
end
```

- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** (`parse/2` reads `body["data"]["markdown"]` and `body["data"]["metadata"]["title"]`; `run` POSTs `https://api.firecrawl.dev/v2/scrape` with `json: %{url: url, formats: ["markdown"]}`, `headers: [{"authorization", "Bearer " <> System.get_env("FIRECRAWL_API_KEY")}]`, `receive_timeout: 60_000`, returns `{:ok, parse(url, body)}`).
- [ ] **Step 4: Run → pass.** Add `@tag :live` scrape test of `https://example.com`.
- [ ] **Step 5:** format, `mix test` green. **Commit** `feat(agent_horde): Firecrawl scrape tool`.

---

### Task 5: Clients + text extraction

**Files:** Create `lib/agent_horde/clients.ex`, `lib/agent_horde/text.ex`; tests in `test/agent_horde_test.exs`.

**Interfaces:**
- `AgentHorde.Clients.claude/0` → `%Normandy.LLM.ClaudioAdapter{}`; `.openai/0` and `.do/0` → `%Normandy.LLM.OpenAICompatibleAdapter{}`. Also `providers/0` → `[{label, client, model}, ...]` for the 3 analysts: `[{"Claude", claude(), "claude-sonnet-4-6"}, {"GPT-4o", openai(), "gpt-4o"}, {"Llama (DO)", do(), "llama3.3-70b-instruct"}]`.
- `AgentHorde.Text.of(response)` → prose string (mirror `CustomerSupport.ChatSession.extract_response_text/1` at `chat_session.ex:258-279`: binary → itself; `%{chat_message: t}` → t; `%{content: list}` → joined text; else `inspect/1`).

- [ ] **Step 1: Failing tests** — `Clients.openai().base_url == "https://api.openai.com/v1"`; `Clients.do().base_url == System.get_env("DO_INFERENCE_URL")`; `length(Clients.providers()) == 3`; `Text.of(%{chat_message: "hi"}) == "hi"`; `Text.of("hi") == "hi"`.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** both modules. `Clients`:

```elixir
defmodule AgentHorde.Clients do
  alias Normandy.LLM.{ClaudioAdapter, OpenAICompatibleAdapter}
  def claude, do: %ClaudioAdapter{api_key: System.get_env("ANTHROPIC_API_KEY"), options: %{timeout: 120_000}}
  def openai, do: %OpenAICompatibleAdapter{api_key: System.get_env("OPENAI_API_KEY"), base_url: "https://api.openai.com/v1", options: %{timeout: 120_000}}
  def do_client, do: %OpenAICompatibleAdapter{api_key: System.get_env("DO_INFERENCE_KEY"), base_url: System.get_env("DO_INFERENCE_URL"), options: %{timeout: 120_000}}
  def providers, do: [{"Claude", claude(), "claude-sonnet-4-6"}, {"GPT-4o", openai(), "gpt-4o"}, {"Llama (DO)", do_client(), "llama3.3-70b-instruct"}]
end
```
(Use `do_client/0` — `do` is reserved.)

- [ ] **Step 4: Run → pass.** **Step 5:** format, `mix test` green. **Commit** `feat(agent_horde): provider clients + response text extraction`.

---

### Task 6: Reasoning agents (Planner, Curator, Analyst, Editor)

**Files:** Create `lib/agent_horde/agents/{planner,curator,analyst,editor}.ex`; tests in `test/agent_horde_test.exs` using `NormandyTest.Support.ModelMockup` (or a local stub Model client) so no network.

**Interfaces:** Each is a `use Normandy.DSL.Agent` module exposing `new(client: , ...)` and `run(agent, input)`. All return **prose** (no io_schema). Models: Planner/Curator/Editor = `claude-sonnet-4-6`; Analyst's baked model is `claude-sonnet-4-6` but is **overridden per provider** at `new` time.

**Reference:** `examples/customer_support_app/lib/customer_support/agents/greeter_agent.ex` for the DSL shape and prose `output_instructions`.

- [ ] **Step 1: Failing test** — each module's `config().model` is correct and `new(client: stub)` returns `{:ok, agent}`. For Analyst, `Analyst.new(client: stub, model: "gpt-4o")` produces an agent whose run uses the override (assert via the stub capturing the model, or just that `new` succeeds with the override key).
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** Planner:

```elixir
defmodule AgentHorde.Agents.Planner do
  use Normandy.DSL.Agent
  agent do
    model "claude-sonnet-4-6"
    temperature 0.5
    background "You plan web research. Given a question, produce focused search queries."
    output_instructions """
    Output ONLY 3 search queries, one per line, no numbering, no commentary,
    no JSON, no code fences. Each query is a concise web search string.
    """
  end
end
```
Curator (`temperature 0.3`, background: "You select the most relevant sources to read in full.", output_instructions: "Given numbered search results, output ONLY the URLs worth scraping, one per line — at most 4, highest-signal first. No commentary, no JSON."). Analyst (`temperature 0.4`, background: "You are a rigorous research analyst.", output_instructions: "Write a concise, factual analysis (4-8 sentences) grounded ONLY in the provided sources. Plain prose. No JSON, no code fences."). Editor (`temperature 0.4`, `max_tokens 4096`, background: "You are an editor synthesizing analyst findings into one report.", output_instructions: "Produce a well-structured Markdown report: a title, a 2-3 sentence summary, key findings as bullets, and a Sources section listing the URLs. Markdown only.").

- [ ] **Step 4: Run → pass.** **Step 5:** format, `mix test` green. **Commit** `feat(agent_horde): planner/curator/analyst/editor agents`.

---

### Task 7: Pipeline orchestration

**Files:** Create `lib/agent_horde/pipeline.ex`; Create `test/support/stub_tool.exs` + pipeline test in `test/agent_horde_test.exs`.

**Interfaces:** `AgentHorde.Pipeline.run(question, opts \\ [])` → `{:ok, %{path: String.t(), report: String.t(), stats: map()}}`. `opts` allows dependency injection for offline tests: `:search_tools` (list of BaseTool structs), `:scrape_tool` (BaseTool struct), `:clients`/`:make_agent` overrides, `:on_event` (fn for CLI logging), `:reports_dir`.

**Stage logic (the heart):**
1. Planner: `{:ok, planner} = Planner.new(client: claude); {_a, r} = Planner.run(planner, question)`; `queries = Text.of(r) |> String.split("\n", trim: true) |> Enum.take(3)`.
2. Search fan-out: for each search tool × each query is too many — instead run **each of the 3 tools once on the joined question** (or first query). Concretely: `tools = opts[:search_tools] || [%ExaSearch{}, %SerpApiSearch{}, %SerperSearch{}]`. Run in parallel:
```elixir
results =
  tools
  |> Task.async_stream(fn tool ->
       t = Map.put(tool, :query, hd(queries))
       Normandy.Tools.BaseTool.run(t)
     end, max_concurrency: 3, timeout: 40_000, on_timeout: :kill_task)
  |> Enum.flat_map(fn {:ok, {:ok, list}} -> list; _ -> [] end)
merged = results |> Enum.uniq_by(& &1.url)
```
3. Curator: feed `merged` as a numbered list to the Curator agent; `urls = Text.of(r) |> extract_urls() |> Enum.take(4)` where `extract_urls/1` regexes `~r{https?://\S+}`. Fallback: if empty, take first 4 `merged` URLs.
4. Scrape fan-out: `scrape = opts[:scrape_tool] || %FirecrawlScrape{}`; parallel over `urls` via `Task.async_stream` → list of `%{url,title,markdown}` (truncate each markdown to ~6000 chars for prompt size).
5. Analyst fan-out (★): `corpus = format_corpus(scraped)`; for each `{label, client, model} <- Clients.providers()` run an `Analyst` in parallel:
```elixir
analyses =
  Clients.providers()
  |> Task.async_stream(fn {label, client, model} ->
       {:ok, a} = Analyst.new(client: client, model: model)
       {_x, r} = Analyst.run(a, "Question: #{question}\n\nSources:\n#{corpus}")
       {label, Text.of(r)}
     end, max_concurrency: 3, timeout: 120_000, on_timeout: :kill_task)
  |> Enum.flat_map(fn {:ok, pair} -> [pair]; _ -> [] end)
```
   (Fail-slow: a dead provider just drops from the list.)
6. Editor: `{:ok, e} = Editor.new(client: claude); {_x, r} = Editor.run(e, editor_prompt(question, analyses, scraped)); report = Text.of(r)`.
7. Writer: `path = Path.join(reports_dir, slug(question) <> "-" <> timestamp() <> ".md"); File.mkdir_p!(reports_dir); File.write!(path, report)`. Return `{:ok, %{path: path, report: report, stats: %{...}}}`.

Emit `opts[:on_event].({stage, payload})` at each stage boundary for the CLI.

- [ ] **Step 1: Write `test/support/stub_tool.exs`** — a `%AgentHorde.Test.StubSearch{}` and `%AgentHorde.Test.StubScrape{}` implementing BaseTool offline (return fixed results), and a stub Model client (or reuse `NormandyTest.Support.ModelMockup`) so agents don't hit network. (Wire `test_helper.exs` to `Code.require_file` the support file.)
- [ ] **Step 2: Failing pipeline test** — `Pipeline.run("test question", search_tools: [%StubSearch{}], scrape_tool: %StubScrape{}, clients: stub, reports_dir: tmp)` returns `{:ok, %{path: p}}` with `File.exists?(p)` and report non-empty. (Provide a `:make_agent`/`:clients` injection so Planner/Curator/Analyst/Editor use the stub Model client.)
- [ ] **Step 3: Run → fail. Step 4: Implement** `pipeline.ex` with the logic above + injection seams. Keep functions small (`plan/2`, `search/3`, `curate/3`, `scrape/3`, `analyze/3`, `edit/3`, `write/3`).
- [ ] **Step 5: Run → pass.** **Step 6:** format, `mix test` green. **Commit** `feat(agent_horde): 7-stage research pipeline`.

---

### Task 8: CLI driver with per-stage logging

**Files:** Create `lib/agent_horde/cli.ex`; smoke assertions in `test/agent_horde_test.exs`.

**Interfaces:** `AgentHorde.CLI.start/0` — prints a banner, prompts `🧠 Ask the horde: `, reads a line, calls `Pipeline.run(question, on_event: &log_event/1)`, prints the report + file path, loops or exits on `/quit`. `log_event/1` renders each stage legibly (the on-camera visual), e.g.:
- `▸ ① Planner → 3 queries`
- `▸ ② Searching: Exa · SerpAPI · Serper (parallel) → N sources`
- `▸ ③ Curator → 4 sources selected`
- `▸ ④ Scraping 4 pages with Firecrawl (parallel)`
- `▸ ⑤ Analyzing on Claude · GPT-4o · Llama [DO] (parallel)`
- `▸ ⑥ Editor → synthesizing report`
- `▸ ⑦ Wrote report → <path>`
Include a per-stage elapsed ms suffix.

- [ ] **Step 1:** Implement `log_event/1` as a pure `format_event(event) :: String.t()` + a thin IO wrapper. **Failing test:** `CLI.format_event({:planner, %{queries: ["a","b","c"]}}) =~ "Planner"`.
- [ ] **Step 2: Run → fail. Step 3: Implement** `cli.ex` (banner, `IO.gets/1` loop, `/quit` handling, calls Pipeline). Keep `start/0` thin; logic in pure formatters.
- [ ] **Step 4: Run → pass.** **Step 5:** format, `mix test` green. **Commit** `feat(agent_horde): interactive CLI with per-stage logging`.

---

### Task 9: Live end-to-end smoke (orchestrator-run, gated)

> This task is **performed by the controller (me)**, not a generic implementer — it needs the live env (sandbox off, real keys). It is verification, not new code, but may surface fixes that loop back to Tasks 1-8.

- [ ] **Step 1:** From repo root, run the live tool tests: `cd examples/agent_horde && mix test --only live` (sandbox off). Expected: Exa/SerpAPI/Serper/Firecrawl each return results. Fix any tool whose live shape differs from the parser.
- [ ] **Step 2:** Run the full pipeline live on a throwaway question via `mix run -e 'IO.inspect(AgentHorde.Pipeline.run("What is Elixir good for?"))'`. Expected: `{:ok, %{path: p}}`, the file exists, the report reads coherently and cites real URLs, and all 3 analyst providers contributed (check stats). Fix issues (e.g. DO model name, OpenAI shape) and re-run.
- [ ] **Step 3:** Run `AgentHorde.CLI.start()` interactively once end-to-end to confirm the on-camera logging reads well.
- [ ] **Step 4: Commit** any fixes with precise messages. Record results in the ledger.

---

### Task 10: Screen-recording video script

**Files:** Create `marketing/demo-1.0/agent-horde-script.md`.

- [ ] **Step 1:** Write the shot-by-shot script: (a) **Setup** — terminal font/size, theme, window ratio, which env vars must be exported, the one command to launch (`cd examples/agent_horde && mix run -e 'AgentHorde.CLI.start()'`); (b) **The question to type** (a crisp, demo-worthy research question that returns rich sources); (c) **Beat-by-beat** — for each of the 7 stages, what appears on screen, a one-line caption/narration suggestion, and rough seconds; (d) **The reveal** — `cat` / open the generated `reports/*.md`, scroll the cited report; (e) **Editing notes** — where to speed-ramp the live latency, suggested captions for the multi-provider beat, total target length (~60-90s). Mark live-latency spots as "safe to time-compress in edit."
- [ ] **Step 2: Commit** `docs(marketing): agent horde screen-recording script`.

---

## Self-Review notes
- **Spec coverage:** adapter (T1), example app (T2), 3 search + scrape tools (T3-4), clients/multi-provider (T5), agents (T6), parallel pipeline (T7), CLI (T8), live verification (T9), script (T10). All spec deliverables mapped.
- **Reliability choices:** tools invoked deterministically (clean structured data); agents return prose (no JSON-leakage); fail-slow analyst fan-out; offline tests only (live tagged + gated to T9).
- **Type consistency:** search tools → `[%{url,title,snippet}]`; scrape → `%{url,title,markdown}`; `Text.of/1` everywhere prose is read from an agent response; `Clients.providers/0` is the single source of the 3 `{label,client,model}` triples used by both pipeline and CLI labels.
- **Open verification items for implementers (flagged inline):** exact default output-schema module with `:chat_message`; `JsonDeserializer` `max_retries: 0` acceptance; `Req.Test` plug mechanism for the installed Req version; `@for.parse/1` resolution inside `defimpl`.
```
