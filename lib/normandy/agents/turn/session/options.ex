defmodule Normandy.Agents.Turn.Session.Options do
  @moduledoc false
  # Turn.Session.new/1's option schema and its :custom validators, in a module with no
  # compile-time dependency on the turn or agent machinery. Turn.Session, Turn.Server,
  # AgentProcess, ResumeReaper and Cluster read these types at compile time (ruling P4: one
  # source for a session key's type); reading them from Turn.Session itself put all of
  # them in one compile-connected cycle.

  alias Normandy.Components.ContentBlock.Describe

  # Modules this schema names, as literal atoms: an alias in the module body is a
  # compile-time dependency, and both reach Turn.Server, which reads this schema at
  # compile time.
  @default_supervisor_mod :"Elixir.Normandy.Agents.Turn.Supervisor"
  @handlers :"Elixir.Normandy.Agents.Turn.Driver.Handlers"
  # A %BaseAgentConfig{} pattern would wait for that struct's module (and through it the
  # Schema compile cycle) while every reader of this schema waits here: on a 4-core
  # runner Elixir 1.20 then reported this module missing to engine/server.ex.
  @base_agent_config :"Elixir.Normandy.Agents.BaseAgentConfig"

  @schema NimbleOptions.new!(
            session_id: [
              type: {:custom, __MODULE__, :validate_session_id, []},
              type_doc: "`t:String.t/0`",
              required: true,
              doc:
                "The session's id: its key in the registry and in the store. A non-empty " <>
                  "string without `{` or `}` (the Redis stores put it inside a cluster hash tag)."
            ],
            registry: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              required: true,
              doc: "The `Normandy.Behaviours.SessionRegistry`, as `{module, handle}`."
            ],
            supervisor: [
              type: {:or, [:pid, :atom, {:tuple, [:atom, :any]}, {:tuple, [:atom, :atom, :any]}]},
              required: true,
              doc: "The supervisor that starts the session's `Turn.Server`: a pid or a name."
            ],
            supervisor_mod: [
              type: {:custom, __MODULE__, :validate_supervisor_mod, []},
              type_doc: "`t:module/0`",
              default: @default_supervisor_mod,
              doc:
                "A `Normandy.Agents.Turn.ServerSupervisor`: the module whose " <>
                  "`start_server/2` starts the server and whose `stop_server/2` stops it " <>
                  "(`Normandy.Agents.Turn.Supervisor.Horde` in a cluster)."
            ],
            store: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              required: true,
              doc: "The `Normandy.Behaviours.SessionStore`, as `{module, handle}`."
            ],
            config: [
              type: {:custom, __MODULE__, :validate_config, []},
              type_doc: "a `%Normandy.Agents.BaseAgentConfig{}`",
              doc:
                "The `%Normandy.Agents.BaseAgentConfig{}` a server starts with. With " <>
                  "`:template_provider` too, it is saved as the session's template on first start."
            ],
            template_provider: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              doc:
                "A `Normandy.Behaviours.AgentTemplate`, as `{module, handle}`: the server " <>
                  "rebuilds its config from the stored template and this node's supplement."
            ],
            template_id: [
              type: :string,
              doc:
                "The supplement's id in the template provider. Default: the config's " <>
                  "`:name`, else `\"default\"`."
            ],
            resume_policy: [
              type: {:in, [:lazy, :eager]},
              default: :lazy,
              doc:
                "`:eager` resumes an unfinished turn when the server restarts, and a Tier-2 " <>
                  "start saves it so `ResumeReaper` restarts the session after a node loss."
            ],
            subscriber: [
              type: {:fun, 2},
              doc: "`fn event_name, meta -> any end`, passed to `Turn.Server`."
            ],
            handlers: [
              type: {:or, [{:struct, @handlers}, nil]},
              type_doc: "a `Normandy.Agents.Turn.Driver.Handlers` or `nil`",
              doc: "A `Turn.Driver.Handlers` set, passed to `Turn.Server`; `nil` is its default."
            ],
            approval_timeout_ms: [
              type: :timeout,
              doc: "Passed to `Turn.Server`, in ms or `:infinity`; saved with a Tier-2 template."
            ],
            on_approval_timeout: [
              type: {:in, [:continue, :fail]},
              doc: "Passed to `Turn.Server`; saved with a Tier-2 template."
            ],
            idle_timeout_ms: [
              type: :timeout,
              doc: "Passed to `Turn.Server`, in ms or `:infinity`; saved with a Tier-2 template."
            ]
          )

  @doc false
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc false
  # Each key's NimbleOptions type, for schemas that take a session key (types only:
  # Session's required/default flags do not apply to them).
  @spec types() :: %{atom() => term()}
  def types, do: Map.new(@schema.schema, fn {key, spec} -> {key, Keyword.fetch!(spec, :type)} end)

  @doc false
  # The types Turn.Server.start_link/1 takes: Session's, except that the server also takes
  # a nil :subscriber (the Session struct's default, passed on as is).
  @spec server_types() :: %{atom() => term()}
  def server_types, do: Map.put(types(), :subscriber, {:or, [{:fun, 2}, nil]})

  @doc false
  # NimbleOptions :custom types. The error never echoes the value: a config holds the
  # client and its credentials, a handle may hold a connection.
  def validate_module_handle({module, _handle} = value) when is_atom(module) and module != nil,
    do: {:ok, value}

  def validate_module_handle(other),
    do: {:error, "expected a {module, handle} tuple, got: " <> Describe.type_of(other)}

  @doc false
  # Redis keys put the id inside a cluster hash tag ("ns:{id}:stream"): a brace in it, or
  # an empty id, would change which part of the key Redis hashes.
  @spec validate_session_id(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_session_id(id) when is_binary(id) and id != "" do
    if String.contains?(id, ["{", "}"]),
      do: {:error, "expected a session id without { or }, got: " <> Describe.type_of(id)},
      else: {:ok, id}
  end

  def validate_session_id(other),
    do: {:error, "expected a non-empty string, got: " <> Describe.type_of(other)}

  @doc false
  # The ServerSupervisor callbacks, checked by export (a host's module need not declare
  # the behaviour).
  @spec validate_supervisor_mod(term()) :: {:ok, module()} | {:error, String.t()}
  def validate_supervisor_mod(mod) when is_atom(mod) and mod != nil do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :start_server, 2) and
         function_exported?(mod, :stop_server, 2) do
      {:ok, mod}
    else
      {:error,
       "expected a module that implements Normandy.Agents.Turn.ServerSupervisor " <>
         "(exports start_server/2 and stop_server/2), got: #{inspect(mod)}"}
    end
  end

  def validate_supervisor_mod(other),
    do: {:error, "expected a module, got: " <> Describe.type_of(other)}

  @doc false
  def validate_config(%{__struct__: @base_agent_config} = config), do: {:ok, config}

  def validate_config(other),
    do:
      {:error, "expected a %Normandy.Agents.BaseAgentConfig{}, got: " <> Describe.type_of(other)}
end
