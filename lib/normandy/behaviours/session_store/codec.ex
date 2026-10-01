defmodule Normandy.Behaviours.SessionStore.Codec do
  @moduledoc false
  # Encoding for the opaque terms the Postgres and Redis stores keep as binaries.
  #
  # Decoding uses `[:safe]`, which refuses atoms that don't exist yet. A node in
  # interactive mode (iex -S mix, mix run, a fresh peer) creates a module's atoms
  # only when the module loads, so a term naming a not-yet-loaded module (a
  # behaviour ref, a schema struct) fails there even though the code exists. On
  # that failure, load the modules of every loaded application (Normandy's
  # included) and decode once more, still with `[:safe]`: only atoms of code
  # that exists get created, and a term with truly unknown atoms still raises.
  # Releases in embedded mode load every module at boot and never hit the retry.

  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)

  @spec decode(binary()) :: term()
  def decode(bin) when is_binary(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError ->
      load_application_modules()
      :erlang.binary_to_term(bin, [:safe])
  end

  defp load_application_modules do
    _ = Application.load(:normandy)

    for {app, _description, _version} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [] do
      _ = Code.ensure_loaded(module)
    end

    :ok
  end
end
