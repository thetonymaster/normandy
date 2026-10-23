defmodule Normandy.Behaviours.ModelCatalogStaticTest do
  @moduledoc """
  DX-33 (decision 27 E6): a config whose model catalog is the deprecated
  `ModelCatalog.Static` logs one warning per VM, from `BaseAgent.init/1` and from
  `ConfigTemplate.rebuild/3`. The flag is VM-global, so this module is not async.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ConfigTemplate}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.ModelCatalog.{ModelsAPI, Static}
  alias Normandy.Test.OwnLog
  alias Normandy.Test.StubClient
  alias Normandy.Test.StubCreds
  alias Normandy.Tools.Toolset

  @warning "Normandy.Behaviours.ModelCatalog.Static is deprecated and will be removed in 3.0; " <>
             "set model_catalog: {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}, which " <>
             "answers the same (this warning is logged once per VM)"

  # init/1 and rebuild/3 log in the caller, so OwnLog keeps exactly their lines.
  setup do
    :persistent_term.erase(Static.warned_key())
    on_exit(fn -> :persistent_term.erase(Static.warned_key()) end)
  end

  defp init(catalog, opts \\ []) do
    BaseAgent.init(%{
      client: %StubClient{},
      model: "m",
      behaviours: %Config{model_catalog: {catalog, opts}, credential: {StubCreds, []}}
    })
  end

  defp supplement do
    %{
      toolset: Toolset.new(),
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> %StubClient{} end
    }
  end

  test "init/1 warns once per VM for ModelCatalog.Static, never for ModelsAPI" do
    assert OwnLog.capture(fn -> init(ModelsAPI) end) == ""

    first = OwnLog.capture(fn -> init(Static, secret: "hunter2") end)
    assert first =~ "[warning] " <> @warning
    refute first =~ "hunter2"

    assert OwnLog.capture(fn -> init(Static) end) == ""
  end

  test "ConfigTemplate.rebuild/3 warns for a template naming ModelCatalog.Static" do
    template = ConfigTemplate.from_config(init(Static), "t")
    :persistent_term.erase(Static.warned_key())

    log = OwnLog.capture(fn -> ConfigTemplate.rebuild(template, supplement(), "TOKEN") end)
    assert log =~ "[warning] " <> @warning
    assert OwnLog.capture(fn -> ConfigTemplate.rebuild(template, supplement(), "TOKEN") end) == ""
  end
end
