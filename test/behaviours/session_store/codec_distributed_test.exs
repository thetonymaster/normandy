defmodule Normandy.Behaviours.SessionStore.CodecDistributedTest do
  @moduledoc """
  A fresh node in interactive mode loads modules lazily, so `[:safe]` decoding of
  a term naming a module it hasn't loaded yet must still work there.
  """
  # async: false — starts peer nodes.
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  alias Normandy.Behaviours.SessionStore.Codec

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    end

    :ok
  end

  test "a peer decodes an atom from a module it has not loaded yet" do
    {peer, node} = start_peer(~c"codec")

    name = "Elixir.Normandy.Test.LazyLoaded"
    blob = <<131, 119, byte_size(name), name::binary>>

    assert Atom.to_string(:erpc.call(node, Codec, :decode, [blob])) == name
    :peer.stop(peer)
  end
end
