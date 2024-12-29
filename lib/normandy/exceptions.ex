defmodule Normandy.CastError do
  @moduledoc """
  Raised when a changeset can't cast a value.
  """
  defexception [:message, :type, :value]

  def exception(opts) do
    type = Keyword.fetch!(opts, :type)
    value = Keyword.fetch!(opts, :value)
    msg = opts[:message] || "cannot cast #{inspect(value)} to #{Normandy.Type.format(type)}"
    %__MODULE__{message: msg, type: type, value: value}
  end
end

defmodule Normandy.NonExistantTurn do
  defexception [:message, :value]

  def exception(opts) do
    value = Keyword.fetch!(opts, :value)

    msg = opts[:message] || "turn #{inspect(value)} does not exist"
    %__MODULE__{message: msg, value: value}
  end
end
