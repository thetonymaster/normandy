defmodule NormandyTest.E2E.Distributed do
  @moduledoc """
  Peer-node side of e2e scenario 11. Compiled (not a script) so `:peer` nodes load it from
  the shared code path. Everything that crosses nodes is a remote function capture or data.
  """

  alias Normandy.Agents.{BaseAgent, ConfigTemplate, Turn}
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.{Config, PolicyEngine}
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionStore.Postgres, as: PG
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Tools.Toolset

  @registry :e2e_registry
  @supervisor :e2e_turn_sup
  @catalog :e2e_catalog
  @template "e2e-s11"
  @sink :e2e_primary_sink
  @model "claude-haiku-4-5-20251001"

  defmodule RefundTool do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use Normandy.Schema

      io_schema "Issue a refund for an order. Needs human approval." do
        field(:order_id, :string, required: true, description: "the order id")
      end
    end

    use Normandy.Tool,
      name: "issue_refund",
      description: "Issue a refund for an order. Needs human approval.",
      input: Input

    alias Normandy.Tools.Context
    alias NormandyTest.E2E.Distributed

    defstruct []

    @impl Normandy.Tool
    def run(_tool, %Context{input: %Input{order_id: id}}) do
      Distributed.sink({:tool_ran, node(), id})
      {:ok, "refund issued for #{id}"}
    end
  end

  def sink_name, do: @sink

  # The primary is a hidden node (so Horde doesn't count it), and :global doesn't sync
  # to hidden nodes; the sink is a locally registered name on the primary instead.
  def sink(msg) do
    case Application.fetch_env(:normandy, :e2e_sink_node) do
      {:ok, primary} -> send({@sink, primary}, msg)
      :error -> raise "e2e sink node not set on #{node()}: boot/4 was not called"
    end
  end

  def boot(normandy_env, claudio_env, repo_opts, sink_node) do
    Application.put_all_env(normandy: normandy_env, claudio: claudio_env)
    Application.put_env(:normandy, :e2e_sink_node, sink_node)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:normandy)

    {:ok, repo} =
      Normandy.TestRepo.start_link(
        Keyword.merge(repo_opts, pool: DBConnection.ConnectionPool, pool_size: 2)
      )

    {:ok, reg} = HReg.start_link(name: @registry)
    {:ok, sup} = HSup.start_link(name: @supervisor)
    {:ok, cat} = Catalog.start_link(name: @catalog)
    :ok = Catalog.put(@catalog, @template, supplement())

    {:ok, reaper} =
      Turn.ResumeReaper.start_link(
        store: store(),
        registry: {HReg, @registry},
        supervisor: @supervisor,
        supervisor_mod: HSup,
        template_provider: {Catalog, @catalog},
        subscriber: &__MODULE__.forward_event/2
      )

    :ok =
      :telemetry.attach(
        "e2e-forward-calls",
        [:claudio, :messages, :create, :stop],
        &__MODULE__.forward_call/4,
        nil
      )

    Enum.each([repo, reg, sup, cat, reaper], &Process.unlink/1)
    :ok
  end

  def members, do: length(Horde.Cluster.members(@registry))

  # A fresh members: :auto registry rejects registrations until it converges
  # (see SessionRegistry.Horde.new/1); true once this node's registry accepts one.
  def registry_ready? do
    probe = {:__e2e_ready_probe__, node(), System.unique_integer([:positive])}

    case Horde.Registry.register(@registry, probe, nil) do
      {:ok, _} ->
        Horde.Registry.unregister(@registry, probe)
        true

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  def build_client(_token) do
    key =
      System.get_env("ANTHROPIC_API_KEY") || System.get_env("API_KEY") ||
        raise "Missing API key on #{node()}"

    %Normandy.LLM.ClaudioAdapter{api_key: key, options: %{timeout: 60_000}}
  end

  def config do
    BaseAgent.init(%{
      client: build_client(nil),
      model: @model,
      max_tokens: 300,
      name: "s11",
      prompt_specification: %Normandy.Components.PromptSpecification{
        background: [
          "You are a helpful assistant in one ongoing conversation; remember what the user tells you."
        ]
      },
      behaviours: %Config{
        credential: {Normandy.Test.StubCreds, []},
        policy:
          {PolicyEngine.Ruleset,
           rules: [%{match: "issue_refund", action: :require_approval, rule_id: "R-refunds"}],
           default_action: :allow}
      }
    })
    |> BaseAgent.register_tool(%RefundTool{})
  end

  def prepare(sid),
    do:
      PG.save_config_template(
        Normandy.TestRepo,
        sid,
        ConfigTemplate.from_config(config(), @template, :eager)
      )

  # `carrier` is the primary's trace context as a W3C carrier (OtelCtx.inject/1): the
  # call runs under it, as a caller on this node would, so the turn's spans join the
  # scenario's trace. `[]` (no OTel) leaves the context alone.
  def run_turn(sid, text, carrier \\ []) do
    OtelCtx.restore(OtelCtx.extract(carrier))

    {:ok, r} =
      Turn.Session.run(Turn.Session.new([config: config()] ++ session_opts(sid)), %{
        chat_message: text
      })

    r.chat_message
  end

  def approve(sid, decisions, carrier \\ []) do
    OtelCtx.restore(OtelCtx.extract(carrier))
    Turn.Session.approve(Turn.Session.new(session_opts(sid)), decisions)
  end

  def owner(sid), do: HReg.whereis(@registry, sid)

  def forward_event(name, meta), do: sink({:session_event, node(), name, meta})
  def forward_call(_event, measurements, _meta, _config), do: sink({:remote_call, measurements})

  defp session_opts(sid) do
    [
      session_id: sid,
      store: store(),
      registry: {HReg, @registry},
      supervisor: @supervisor,
      supervisor_mod: HSup,
      template_provider: {Catalog, @catalog},
      template_id: @template,
      resume_policy: :eager,
      subscriber: &__MODULE__.forward_event/2
    ]
  end

  defp supplement do
    %{
      toolset: Toolset.new([%RefundTool{}]),
      before_hooks: [],
      after_hooks: [],
      client_builder: &__MODULE__.build_client/1
    }
  end

  defp store, do: {PG, Normandy.TestRepo}
end
