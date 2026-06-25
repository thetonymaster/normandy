defmodule AutoresumeDemo.AgentTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.Agent
  alias AutoresumeDemo.SimClient
  alias Normandy.LLM.ClaudioAdapter

  test "client_builder returns a SimClient in simulated mode" do
    prev = Application.get_env(:autoresume_demo, :demo_mode)
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    on_exit(fn -> Application.put_env(:autoresume_demo, :demo_mode, prev) end)

    assert %SimClient{} = Agent.client_builder().("tok")
  end

  test "client_builder returns a ClaudioAdapter carrying the token in real mode" do
    prev = Application.get_env(:autoresume_demo, :demo_mode)
    Application.put_env(:autoresume_demo, :demo_mode, :real)
    on_exit(fn -> Application.put_env(:autoresume_demo, :demo_mode, prev) end)

    assert %ClaudioAdapter{api_key: "tok"} = Agent.client_builder().("tok")
  end

  test "the eager template carries the credential ref for Tier-2 reconstruction" do
    tmpl = Agent.build_template()
    assert tmpl.resume_policy == :eager
    assert tmpl.behaviours_refs.credential == {AutoresumeDemo.EnvCredentialProvider, []}
    assert tmpl.template_id == Agent.template_id()
  end

  test "warmup/0 round-trips a Turn.State for every status and is idempotent" do
    # warmup must not raise: each constructed status/stop_reason Turn.State has to
    # survive the [:safe] round-trip (the pinned matches inside warmup/0 raise
    # MatchError on mismatch or :badarg on an un-interned atom). Idempotent — safe
    # to call on every node at boot, possibly more than once.
    assert :ok = Agent.warmup()
    assert :ok = Agent.warmup()

    # Guard against regressing the value-atom interning gap: a non-default status
    # (the :steering state whose decode raised :badarg on a fresh peer) must
    # survive the same [:safe] path the store uses after warmup has run.
    state = %Normandy.Agents.Turn.State{status: :steering, stop_reason: :max_iterations}
    assert ^state = :erlang.binary_to_term(:erlang.term_to_binary(state), [:safe])
  end

  test "a stored closure reads demo_mode at invocation time, not build time" do
    prev = Application.get_env(:autoresume_demo, :demo_mode)
    on_exit(fn -> Application.put_env(:autoresume_demo, :demo_mode, prev) end)

    # Build the closure under :real mode (as a Catalog supplement would at boot).
    Application.put_env(:autoresume_demo, :demo_mode, :real)
    builder = Agent.client_builder()
    assert %ClaudioAdapter{api_key: "tok"} = builder.("tok")

    # Switch the mode AFTER the closure was built, then invoke the SAME closure.
    # It must reflect the new mode (handoff reconstruction reads current env).
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    assert %SimClient{} = builder.("tok")
  end
end
