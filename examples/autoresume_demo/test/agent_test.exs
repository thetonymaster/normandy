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
end
