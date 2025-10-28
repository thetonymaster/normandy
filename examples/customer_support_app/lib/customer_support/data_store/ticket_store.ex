defmodule CustomerSupport.DataStore.TicketStore do
  @moduledoc """
  ETS-backed ticket storage for tracking customer support issues.

  Manages support tickets with priority levels, categories, and status tracking.
  """

  use GenServer
  require Logger

  @table_name :tickets

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new support ticket.
  """
  def create_ticket(ticket_data) do
    ticket_id = generate_ticket_id()

    ticket =
      ticket_data
      |> Map.put(:ticket_id, ticket_id)
      |> Map.put_new(:status, "open")
      |> Map.put_new(:created_at, DateTime.utc_now())

    :ets.insert(@table_name, {ticket_id, ticket})
    {:ok, ticket_id}
  end

  @doc """
  Get ticket by ID.
  """
  def get_ticket(ticket_id) do
    case :ets.lookup(@table_name, ticket_id) do
      [{^ticket_id, ticket}] -> {:ok, ticket}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Update ticket status.
  """
  def update_ticket_status(ticket_id, new_status) do
    case get_ticket(ticket_id) do
      {:ok, ticket} ->
        updated_ticket = Map.put(ticket, :status, new_status)
        :ets.insert(@table_name, {ticket_id, updated_ticket})
        {:ok, updated_ticket}

      error ->
        error
    end
  end

  @doc """
  List all tickets, optionally filtered by status.
  """
  def list_tickets(status \\ nil) do
    tickets =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_key, ticket} -> ticket end)

    case status do
      nil -> tickets
      status -> Enum.filter(tickets, fn t -> t.status == status end)
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("TicketStore initialized")
    {:ok, %{table: table, counter: 0}}
  end

  # Private Functions

  defp generate_ticket_id do
    "TKT-#{:rand.uniform(999999) |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end
end
