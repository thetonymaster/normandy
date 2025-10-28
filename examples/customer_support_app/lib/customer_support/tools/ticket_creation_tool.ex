defmodule CustomerSupport.Tools.TicketCreationTool do
  @moduledoc """
  Tool for creating support tickets for issues requiring follow-up.

  Creates tracked tickets with priority levels and categories for issues
  that cannot be immediately resolved.
  """

  defstruct [:title, :description, :category, :priority, :customer_email]

  defimpl Normandy.Tools.BaseTool do
    alias CustomerSupport.DataStore.TicketStore

    def tool_name(_), do: "create_ticket"

    def tool_description(_) do
      """
      Create a support ticket for issues requiring follow-up or escalation.
      Returns a ticket ID that can be used to track the issue.
      """
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          title: %{
            type: "string",
            description: "Brief title summarizing the issue"
          },
          description: %{
            type: "string",
            description: "Detailed description of the issue"
          },
          category: %{
            type: "string",
            description: "Issue category",
            enum: ["technical", "billing", "shipping", "product", "other"]
          },
          priority: %{
            type: "string",
            description: "Issue priority level",
            enum: ["low", "medium", "high", "urgent"]
          },
          customer_email: %{
            type: "string",
            description: "Customer email for follow-up"
          }
        },
        required: ["title", "description", "category", "priority"]
      }
    end

    def run(params) do
      ticket = %{
        title: params.title,
        description: params.description,
        category: params.category,
        priority: params.priority,
        customer_email: Map.get(params, :customer_email),
        status: "open",
        created_at: DateTime.utc_now()
      }

      case TicketStore.create_ticket(ticket) do
        {:ok, ticket_id} ->
          {:ok, format_ticket_confirmation(ticket_id, ticket)}

        {:error, reason} ->
          {:error, "Failed to create ticket: #{inspect(reason)}"}
      end
    end

    defp format_ticket_confirmation(ticket_id, ticket) do
      """
      Support Ticket Created Successfully

      Ticket ID: #{ticket_id}
      Title: #{ticket.title}
      Category: #{ticket.category}
      Priority: #{ticket.priority}
      Status: #{ticket.status}

      #{email_confirmation(ticket.customer_email)}

      Our support team will review this ticket and follow up within:
      #{sla_message(ticket.priority)}
      """
    end

    defp email_confirmation(nil), do: ""

    defp email_confirmation(email) do
      "A confirmation email will be sent to: #{email}"
    end

    defp sla_message("urgent"), do: "1 hour"
    defp sla_message("high"), do: "4 hours"
    defp sla_message("medium"), do: "24 hours"
    defp sla_message("low"), do: "48 hours"
  end
end
