defmodule Normandy.ApplicationSpecTest do
  # async: false — switches the global Mix env.
  use ExUnit.Case, async: false

  # The test env adds :mnesia for the Mnesia store's own tests; consumers get
  # the non-test spec, which is what this checks.
  test "outside tests, Normandy does not start Mnesia" do
    previous = Mix.env()
    Mix.env(:prod)

    try do
      refute :mnesia in Keyword.fetch!(Normandy.MixProject.application(), :extra_applications)
    after
      Mix.env(previous)
    end
  end
end
