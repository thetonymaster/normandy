defmodule Normandy.ClusterTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RedisReg
  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore

  defp ids(specs), do: Enum.map(specs, &spec_id/1)
  defp spec_id(%{id: id}), do: id
  defp spec_id({mod, _args}), do: mod

  test "child_specs returns the horde registry + supervisor specs" do
    specs = Normandy.Cluster.child_specs(registry: :my_reg, supervisor: :my_sup)
    assert :my_reg in ids(specs)
    assert :my_sup in ids(specs)
  end

  test "the reaper spec is included only when store + template_provider are given" do
    without = Normandy.Cluster.child_specs(registry: :r, supervisor: :s)
    refute ResumeReaper in ids(without)

    with_reaper =
      Normandy.Cluster.child_specs(
        registry: :r,
        supervisor: :s,
        store: {Normandy.Behaviours.SessionStore.InMemory, :h},
        template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, :c}
      )

    assert ResumeReaper in ids(with_reaper)
  end

  test "the reaper spec carries the registry/supervisor/store/template handles" do
    [reaper] =
      Normandy.Cluster.child_specs(
        registry: :r,
        supervisor: :s,
        store: {Normandy.Behaviours.SessionStore.InMemory, :h},
        template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, :c}
      )
      |> Enum.filter(&(spec_id(&1) == ResumeReaper))

    {ResumeReaper, :start_link, [opts]} = reaper.start
    assert opts[:registry] == {Normandy.Behaviours.SessionRegistry.Horde, :r}
    assert opts[:supervisor] == :s
    assert opts[:supervisor_mod] == Normandy.Agents.Turn.Supervisor.Horde
    assert opts[:store] == {Normandy.Behaviours.SessionStore.InMemory, :h}
    assert opts[:template_provider] == {Normandy.Behaviours.AgentTemplate.Catalog, :c}
  end

  test "libcluster spec is omitted when no topologies are given" do
    specs = Normandy.Cluster.child_specs(registry: :r, supervisor: :s)
    refute Cluster.Supervisor in ids(specs)
  end

  describe "the Redis combo" do
    @combo [
      redix: [name: :combo_redix, host: "localhost"],
      namespace: "combo",
      registry: :combo_reg,
      supervisor: :combo_sup,
      template_provider: {Catalog, :c}
    ]

    test "redis_handles/1 returns the registry's handle struct and the store's handle" do
      assert Normandy.Cluster.redis_handles(@combo) == %{
               registry:
                 {RedisReg,
                  %RedisReg.Handle{owner: :combo_reg, conn: :combo_redix, namespace: "combo"}},
               store: {RedisStore, {:combo_redix, "combo"}}
             }
    end

    test "the reaper gets the handles redis_handles/1 returns" do
      [reaper] =
        @combo
        |> Normandy.Cluster.redis_child_specs()
        |> Enum.filter(&(spec_id(&1) == {ResumeReaper, :combo_reg}))

      {ResumeReaper, :start_link, [opts]} = reaper.start
      handles = Normandy.Cluster.redis_handles(@combo)
      assert opts[:registry] == handles.registry
      assert opts[:store] == handles.store
    end
  end
end
