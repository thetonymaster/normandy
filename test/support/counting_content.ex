defmodule Normandy.Test.CountingContent do
  @moduledoc """
  Memory content that counts its encodings: each `BaseIOSchema.to_json/1` of it adds 1
  to slot 1 of `ref` (a `:counters` ref) and returns `text`. Tests of Task 6.1 use it to
  prove a message is encoded once, however many requests carry it.
  """

  @enforce_keys [:ref]
  defstruct [:ref, text: "counted"]

  @type t :: %__MODULE__{ref: :counters.counters_ref(), text: String.t()}

  @doc "A counter for `new/2`, starting at 0."
  @spec counter() :: :counters.counters_ref()
  def counter, do: :counters.new(1, [])

  @doc "Content counting into `ref`, sent to the model as `text`."
  @spec new(:counters.counters_ref(), String.t()) :: t()
  def new(ref, text \\ "counted"), do: %__MODULE__{ref: ref, text: text}

  @doc "How many times content counting into `ref` was encoded."
  @spec count(:counters.counters_ref()) :: non_neg_integer()
  def count(ref), do: :counters.get(ref, 1)
end

defimpl Normandy.Components.BaseIOSchema, for: Normandy.Test.CountingContent do
  def to_json(%{ref: ref, text: text}) do
    :counters.add(ref, 1, 1)
    text
  end

  def get_schema(_content), do: %{}
end
