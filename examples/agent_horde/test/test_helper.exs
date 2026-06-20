ExUnit.configure(exclude: [:live])
ExUnit.start()

Code.require_file("support/stub_tool.exs", __DIR__)
