defmodule CustomerSupport.Application do
  @moduledoc """
  OTP Application for the Customer Support system.

  Starts and supervises all necessary processes:
  - Data stores (OrderStore, TicketStore, KnowledgeBase)
  - Session manager (ChatSession)
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting CustomerSupport Application...")

    children = [
      # Data Stores
      {CustomerSupport.DataStore.OrderStore, []},
      {CustomerSupport.DataStore.TicketStore, []},
      {CustomerSupport.DataStore.KnowledgeBase, []},

      # Session Manager
      {CustomerSupport.ChatSession, []}
    ]

    opts = [strategy: :one_for_one, name: CustomerSupport.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("CustomerSupport Application started successfully")
        {:ok, pid}

      error ->
        Logger.error("Failed to start CustomerSupport Application: #{inspect(error)}")
        error
    end
  end
end
