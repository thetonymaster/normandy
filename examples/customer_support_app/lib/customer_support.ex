defmodule CustomerSupport do
  @moduledoc """
  Production-ready customer support application built with Normandy.

  Demonstrates:
  - Multi-agent coordination with specialized agents
  - Tool integration for data access
  - ETS-backed data stores
  - Session management
  - OTP supervision tree

  ## Architecture

  ```
  Application
  ├── OrderStore (GenServer)
  ├── TicketStore (GenServer)
  ├── KnowledgeBase (GenServer)
  └── ChatSession (GenServer)
  ```

  ## Agents

  - **GreeterAgent**: Initial triage and routing
  - **OrderSupportAgent**: Order tracking and shipping
  - **TechnicalSupportAgent**: Product troubleshooting
  - **BillingSupportAgent**: Refunds and billing issues

  ## Usage

      # Start application
      {:ok, _} = Application.ensure_all_started(:customer_support)

      # Create session
      {:ok, session_id} = CustomerSupport.create_session()

      # Send messages
      CustomerSupport.send_message(session_id, "I need help with order ORD-12345")

      # Get conversation history
      CustomerSupport.get_history(session_id)
  """

  alias CustomerSupport.ChatSession

  @doc """
  Create a new customer support session.
  """
  def create_session do
    ChatSession.create_session()
  end

  @doc """
  Send a message to a support session.
  """
  def send_message(session_id, message) do
    ChatSession.send_message(session_id, message)
  end

  @doc """
  Get conversation history for a session.
  """
  def get_history(session_id) do
    ChatSession.get_history(session_id)
  end

  @doc """
  End a support session.
  """
  def end_session(session_id) do
    ChatSession.end_session(session_id)
  end
end
