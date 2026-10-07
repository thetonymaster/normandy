defmodule Normandy.Agents.Turn.Session do
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn.{Server, Start, Supervisor}
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.TurnError

  # Plain-data server options saved with a Tier-2 template, so a server started
  # without them (e.g. by ResumeReaper) restores them. Functions (:subscriber,
  # :handlers) cannot be stored; the starter must pass those.
  @stored_server_options [:approval_timeout_ms, :on_approval_timeout, :idle_timeout_ms]

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
              type: :atom,
              default: Supervisor,
              doc:
                "The module whose `start_server/2` starts the server " <>
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
              type: {:or, [{:struct, Normandy.Agents.Turn.Driver.Handlers}, nil]},
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
  # The session keys' types; Turn.Server and AgentProcess reuse them (ruling P4).
  @spec __opts_schema__(:new) :: NimbleOptions.t()
  def __opts_schema__(:new), do: @schema

  @moduledoc """
  A handle on one durable session. `new/1` checks the options once; `run/2` routes a turn
  to the session's `Turn.Server` and `approve/2` delivers approval decisions to it.

      session =
        Turn.Session.new(
          session_id: "user-42",
          config: config,
          store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo},
          registry: {Normandy.Behaviours.SessionRegistry.Native, MyApp.SessionRegistry},
          supervisor: MyApp.TurnSupervisor
        )

      {:ok, output} = Turn.Session.run(session, "hello")

  `run/2` resolves `session_id` to a live pid via the `SessionRegistry`; on a miss, it
  starts a `Turn.Server` under the supervisor with the **caller-supplied** config (the
  store never holds config/credentials). The server loads its turn state and
  conversation memory from the `SessionStore` on every start, so a supervisor restart
  resumes from the store, not from the state captured when the session first started.
  A `%Turn.Session{}` is plain data: building one starts nothing, and the same handle can
  be used from any process.

  ## Options

  #{Normandy.Options.docs(@schema)}

  ## Tier-2 thin start (when `:template_provider` is set)

  With a `:config` and a `:template_provider`, the first start persists a secret-free
  `ConfigTemplate` derived from the config, then launches `Turn.Server` with **thin**
  options (no `:config`). The server reconstructs the full config node-locally from the
  stored template + supplement + credential token. Later starts (after passivation)
  find the persisted template in the store and reconstruct without any caller config.

  A session may also have only a `:template_provider` (no `:config`), for example on a
  surviving node after the session's node died: the server starts from the template
  already saved in the store. With no saved template, `run/2` returns
  `{:error, %Normandy.TurnError{type: :session_unavailable, reason:
  {:no_config_template, session_id}}}`.

  ## Resume policy (`:resume_policy`, `:lazy` or `:eager`)

  `:lazy` (default) restarts a session only when a caller routes to it. With
  `:eager`, a restarted server resumes a non-terminal turn on its own, and a
  Tier-2 start saves the policy in the template, so `ResumeReaper` restarts the
  session when its node goes down. A session started from a saved template keeps
  the policy it was saved with.

  ## Start-time race

  For `:self_register` (Native) registries the race between `whereis` returning
  `:none` and the new child finishing `register/3` is best-effort: a concurrent
  caller may start a second child, which then loses the race and keeps running
  unregistered. This was acceptable for single-router usage.

  For via-based registries (Horde) the race is **closed**: the supervisor supplies
  a `:name` computed by `child_name/2`, so the OTP supervisor performs atomic
  registration at start. Any concurrent caller that loses the start race gets
  `{:error, {:already_started, pid}}`, which `run/2` treats as `{:ok, pid}` so all
  callers converge on the single winner.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          registry: {module(), term()},
          supervisor: GenServer.server(),
          supervisor_mod: module(),
          store: {module(), term()},
          config: BaseAgentConfig.t() | nil,
          template_provider: {module(), term()} | nil,
          template_id: String.t() | nil,
          resume_policy: :lazy | :eager,
          subscriber: (atom(), map() -> any()) | nil,
          handlers: Normandy.Agents.Turn.Driver.Handlers.t() | nil,
          server_options: keyword()
        }

  @enforce_keys [:session_id, :registry, :supervisor, :store]
  defstruct [
    :session_id,
    :registry,
    :supervisor,
    :store,
    :config,
    :template_provider,
    :template_id,
    :subscriber,
    :handlers,
    supervisor_mod: Supervisor,
    resume_policy: :lazy,
    server_options: []
  ]

  @doc """
  Builds a session handle. Starts nothing.

  Raises `ArgumentError` naming the key for an unknown key, a missing required key or a
  value of the wrong type, and when neither `:config` nor `:template_provider` is given.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Normandy.Options.validate!(opts, @schema, {__MODULE__, :new, 1})

    unless Keyword.has_key?(opts, :config) or Keyword.has_key?(opts, :template_provider) do
      raise ArgumentError,
            "Normandy.Agents.Turn.Session.new/1: requires :config " <>
              "(a %Normandy.Agents.BaseAgentConfig{}) or :template_provider " <>
              "({module, handle}), got neither"
    end

    struct!(
      __MODULE__,
      [server_options: Keyword.take(opts, @stored_server_options)] ++
        Keyword.drop(opts, @stored_server_options)
    )
  end

  def new(other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Session.new/1: expected a keyword list, got: " <>
            Describe.type_of(other)
  end

  @doc """
  Routes a turn to the session's server, starting it if needed, and returns what
  `Turn.Server.run/2` returns: `{:ok, output}` or `{:error, exception}`. A session that
  cannot be started (a registry or store fault, no saved template) returns
  `{:error, %Normandy.TurnError{type: :session_unavailable, reason: reason}}`. A server
  option `Turn.Server` rejects (only reachable by editing the struct, since `new/1` checks
  them too) raises `ArgumentError` in the caller, from `Turn.Supervisor.start_server/2`
  (Ruling 7).
  """
  @spec run(t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def run(%__MODULE__{} = session, user_input) do
    case ensure_server(session) do
      {:ok, pid} ->
        Server.run(pid, user_input)

      # A start function that raised comes back from the supervisor as
      # {exception, stacktrace}: the stacktrace is dropped (decision 6).
      {:error, reason} ->
        {:error,
         %TurnError{type: :session_unavailable, reason: TurnError.drop_stacktraces(reason)}}
    end
  end

  def run(other, _user_input), do: raise(ArgumentError, not_a_session(:run, other))

  @doc """
  Delivers approval decisions (`tool_call_id => :approve | :reject`) to the session's
  parked server and returns `:ok`; the turn's result goes to the `run/2` caller waiting
  on it. Never starts a server: with none live it returns `{:error,
  %Normandy.TurnError{type: :session_unavailable, reason: :no_session}}`, and a registry
  that cannot answer returns that `TurnError` with the registry's reason.
  """
  @spec approve(t(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, TurnError.t()}
  def approve(%__MODULE__{registry: {reg_mod, reg_handle}, session_id: sid}, decisions) do
    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} ->
        Server.approve(pid, decisions)

      # Approval only makes sense against a live, parked server. An
      # awaiting-approval server never passivates (only :idle does), so a
      # registry miss means there is no session to approve: fail closed
      # instead of booting a fresh server and silently dropping the approval.
      :none ->
        {:error, %TurnError{type: :session_unavailable, reason: :no_session}}

      {:error, reason} ->
        {:error, %TurnError{type: :session_unavailable, reason: reason}}
    end
  end

  def approve(other, _decisions), do: raise(ArgumentError, not_a_session(:approve, other))

  @doc """
  Returns `session` with `config` as the config a later server start uses (a first
  start, a restart after passivation, a Tier-2 template save). A live server keeps the
  config it started with.
  """
  @spec put_config(t(), BaseAgentConfig.t()) :: t()
  def put_config(%__MODULE__{} = session, %BaseAgentConfig{} = config),
    do: %{session | config: config}

  def put_config(%__MODULE__{}, other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Session.put_config/2: expected a " <>
            "%Normandy.Agents.BaseAgentConfig{}, got: " <> Describe.type_of(other)
  end

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
  def validate_config(%BaseAgentConfig{} = config), do: {:ok, config}

  def validate_config(other),
    do:
      {:error, "expected a %Normandy.Agents.BaseAgentConfig{}, got: " <> Describe.type_of(other)}

  defp not_a_session(fun, other) do
    "Normandy.Agents.Turn.Session.#{fun}/2: expected a %Normandy.Agents.Turn.Session{} " <>
      "(build one with Normandy.Agents.Turn.Session.new/1), got: " <> Describe.type_of(other)
  end

  defp ensure_server(%__MODULE__{registry: {reg_mod, reg_handle}, session_id: sid} = session) do
    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} -> {:ok, pid}
      :none -> rehydrate_and_start(session)
      # The registry could not answer: starting would risk a second server.
      {:error, reason} -> {:error, reason}
    end
  end

  # Turn.Server.init/1 loads the turn state and rebuilds memory from the store
  # itself (on every start, including supervisor restarts), so the server opts
  # carry only the caller's config and options. A store fault in that load
  # comes back as run/2's {:error, reason} (the server starts :unavailable).
  defp rehydrate_and_start(%__MODULE__{} = session) do
    {reg_mod, reg_handle} = session.registry

    with {:ok, server_opts} <- server_opts(session) do
      Start.start_server(
        session.supervisor_mod,
        session.supervisor,
        server_opts,
        {reg_mod, reg_handle},
        session.session_id
      )
    end
  end

  # Three ways to start: a :config with no template provider (Tier 0/1); a :config
  # with a template provider, which saves the template first (Tier 2, first
  # start); or a template provider alone, which starts from the template already
  # in the store (Tier 2, e.g. a caller on a surviving node that has no config).
  # new/1 guarantees at least one of the two.
  defp server_opts(%__MODULE__{config: config, template_provider: nil} = session)
       when config != nil,
       do: {:ok, Keyword.put(base_server_opts(session), :config, config)}

  defp server_opts(%__MODULE__{config: nil} = session) do
    case load_template(session) do
      {:ok, _tmpl} -> {:ok, thin_server_opts(session)}
      :error -> {:error, {:no_config_template, session.session_id}}
      {:error, reason} -> {:error, Describe.reason_term(reason)}
    end
  end

  # A store's reason reaches every run/2 caller, so it is reduced to its tags like the
  # load reasons Turn.Server replies (Describe.reason_term/1).
  defp server_opts(%__MODULE__{config: config} = session) do
    case save_template(session, config) do
      :ok -> {:ok, thin_server_opts(session)}
      {:error, reason} -> {:error, Describe.reason_term(reason)}
    end
  end

  defp save_template(%__MODULE__{store: {store_mod, store_handle}} = session, config) do
    tmpl =
      config
      |> ConfigTemplate.from_config(template_id_of(session, config), session.resume_policy)
      |> Map.put(:server_options, Map.new(session.server_options))

    store_mod.save_config_template(store_handle, session.session_id, tmpl)
  end

  defp load_template(%__MODULE__{store: {store_mod, store_handle}, session_id: sid}),
    do: store_mod.load_config_template(store_handle, sid)

  # The options Turn.Server.start_link/1 takes. :subscriber and :handlers only when set,
  # as before (Keyword.take of the caller's list).
  defp base_server_opts(%__MODULE__{} = session) do
    [session_id: session.session_id, store: session.store, registry: session.registry]
    |> put_set(:subscriber, session.subscriber)
    |> put_set(:handlers, session.handlers)
    |> Keyword.merge(session.server_options)
    |> Keyword.put(:resume_policy, session.resume_policy)
  end

  defp put_set(opts, _key, nil), do: opts
  defp put_set(opts, key, value), do: Keyword.put(opts, key, value)

  defp thin_server_opts(%__MODULE__{} = session),
    do: Keyword.put(base_server_opts(session), :template_provider, session.template_provider)

  defp template_id_of(%__MODULE__{template_id: template_id}, config),
    do: template_id || config.name || "default"
end
