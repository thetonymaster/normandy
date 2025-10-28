defmodule CustomerSupport.Tools.RefundProcessorTool do
  @moduledoc """
  Tool for processing refund requests for eligible orders.

  Validates refund eligibility based on order status and time since purchase,
  then initiates the refund process.
  """

  defstruct [:order_id, :reason, :amount]

  defimpl Normandy.Tools.BaseTool do
    alias CustomerSupport.DataStore.OrderStore

    def tool_name(_), do: "process_refund"

    def tool_description(_) do
      """
      Process a refund request for an order. Validates eligibility and
      initiates the refund. Can process full or partial refunds.
      """
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          order_id: %{
            type: "string",
            description: "The order ID to refund"
          },
          reason: %{
            type: "string",
            description: "Reason for the refund",
            enum: ["defective", "wrong_item", "not_as_described", "changed_mind", "other"]
          },
          amount: %{
            type: "number",
            description: "Refund amount (optional, defaults to full order amount)"
          }
        },
        required: ["order_id", "reason"]
      }
    end

    def run(%{order_id: order_id, reason: reason} = params) do
      with {:ok, order} <- OrderStore.get_order(order_id),
           :ok <- validate_refund_eligibility(order),
           refund_amount <- Map.get(params, :amount, order.total),
           :ok <- validate_refund_amount(refund_amount, order.total),
           {:ok, refund_id} <- process_refund(order_id, refund_amount, reason) do
        {:ok, format_refund_confirmation(refund_id, order_id, refund_amount, reason)}
      else
        {:error, :not_found} ->
          {:error, "Order #{order_id} not found"}

        {:error, :ineligible, reason} ->
          {:error, "Refund not allowed: #{reason}"}

        {:error, :invalid_amount} ->
          {:error, "Refund amount exceeds order total"}

        {:error, reason} ->
          {:error, "Refund processing failed: #{inspect(reason)}"}
      end
    end

    defp validate_refund_eligibility(order) do
      cond do
        order.status == "cancelled" ->
          {:error, :ineligible, "Order is already cancelled"}

        order.status == "refunded" ->
          {:error, :ineligible, "Order has already been refunded"}

        days_since_order(order) > 30 ->
          {:error, :ineligible, "Order is outside 30-day refund window"}

        true ->
          :ok
      end
    end

    defp validate_refund_amount(refund_amount, order_total) do
      if refund_amount <= order_total do
        :ok
      else
        {:error, :invalid_amount}
      end
    end

    defp process_refund(order_id, amount, reason) do
      refund_id = "REF-#{:rand.uniform(99999) |> Integer.to_string() |> String.pad_leading(5, "0")}"

      refund = %{
        refund_id: refund_id,
        order_id: order_id,
        amount: amount,
        reason: reason,
        status: "processing",
        created_at: DateTime.utc_now()
      }

      # Update order status
      OrderStore.update_order_status(order_id, "refund_processing")

      {:ok, refund_id}
    end

    defp format_refund_confirmation(refund_id, order_id, amount, reason) do
      """
      Refund Initiated Successfully

      Refund ID: #{refund_id}
      Order ID: #{order_id}
      Amount: $#{amount}
      Reason: #{format_reason(reason)}
      Status: Processing

      The refund will be processed within 3-5 business days.
      You will receive a confirmation email once the refund is completed.
      The funds will appear in your original payment method within 5-10 business days.
      """
    end

    defp format_reason("defective"), do: "Defective product"
    defp format_reason("wrong_item"), do: "Wrong item received"
    defp format_reason("not_as_described"), do: "Not as described"
    defp format_reason("changed_mind"), do: "Changed mind"
    defp format_reason("other"), do: "Other"

    defp days_since_order(order) do
      if order.created_at do
        DateTime.diff(DateTime.utc_now(), order.created_at, :day)
      else
        0
      end
    end
  end
end
