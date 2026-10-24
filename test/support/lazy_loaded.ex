defmodule Normandy.Test.LazyLoaded do
  @moduledoc false
  # Referenced by no code: its atom exists in a VM only once this module loads.
  # SessionStore.CodecTest decodes a term naming it, built from a string.
end
