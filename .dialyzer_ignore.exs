[
  # Protocol implementations may have dynamic types
  ~r":0:unknown_type Function Normandy.Components.BaseIOSchema.*",

  # Weather tool uses Erlang :inets and :httpc modules
  ~r"lib/normandy/tools/examples/weather\.ex.*unknown_function.*Function :inets\.start",
  ~r"lib/normandy/tools/examples/weather\.ex.*unknown_function.*Function :httpc\.request",

  # Dialyzer false positive - compress_conversation can return early or continue
  {"lib/normandy/context/summarizer.ex", :pattern_match},

  # Supertype warnings - these are overly strict type specs that are intentionally broader
  ~r"is a supertype of the success typing"
]
