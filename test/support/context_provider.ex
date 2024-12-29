defmodule Normandy.Support.ContextProvider do
  use Normandy.Schema

  schema do
    field(:title, :string)
    field(:some_stuff, :string)
  end

  defimpl Normandy.Components.ContextProvider, for: __MODULE__ do
    def title(config) do
      config.title
    end

    def get_info(config) do
      config.some_stuff
    end
  end
end
