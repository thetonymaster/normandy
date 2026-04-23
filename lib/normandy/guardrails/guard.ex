defmodule Normandy.Guardrails.Guard do
  @moduledoc """
  Behaviour for guardrails that inspect agent input or output.

  A guard is a module that implements `check/2`. It is called with a runtime
  value (either the agent's validated input or its validated output) and the
  guard's options. It must return `:ok` to allow the value through, or
  `{:error, [violation]}` to reject it.

  Violations use the same `%{path, message, constraint}` shape as
  `Normandy.Agents.ValidationMiddleware`, with an additional `:guard` key
  identifying the module that produced the violation. This means
  `Normandy.Agents.ValidationMiddleware.error_message/1` renders guardrail
  violations without modification.

  ## Example

      defmodule MyApp.NoShouting do
        @behaviour Normandy.Guardrails.Guard

        @impl true
        def check(value, _opts) when is_binary(value) do
          if value == String.upcase(value) and String.length(value) > 3 do
            {:error,
             [
               %{
                 guard: __MODULE__,
                 path: [],
                 message: "must not be all caps",
                 constraint: :no_shouting
               }
             ]}
          else
            :ok
          end
        end

        def check(_value, _opts), do: :ok
      end
  """

  @type violation :: %{
          :guard => module(),
          :path => [atom()],
          :message => String.t(),
          :constraint => atom(),
          optional(atom()) => term()
        }

  @callback check(value :: term(), opts :: keyword()) :: :ok | {:error, [violation()]}
end
