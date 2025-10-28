defmodule CustomerSupport.Tools.OrderLookupTool do
  @moduledoc """
  Tool for looking up order information from the order database.

  Retrieves order details including status, items, tracking information,
  and estimated delivery dates.
  """

  defstruct [:order_id]

  defimpl Normandy.Tools.BaseTool do
    alias CustomerSupport.DataStore.OrderStore

    def tool_name(_), do: "order_lookup"

    def tool_description(_) do
      """
      Look up order information by order ID. Returns order status, items,
      tracking number, and estimated delivery date if available.
      """
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          order_id: %{
            type: "string",
            description: "The order ID to look up (format: ORD-XXXXX)"
          }
        },
        required: ["order_id"]
      }
    end

    def run(%{order_id: order_id}) do
      case OrderStore.get_order(order_id) do
        {:ok, order} ->
          {:ok, format_order(order)}

        {:error, :not_found} ->
          {:error, "Order #{order_id} not found. Please verify the order ID."}

        {:error, reason} ->
          {:error, "Failed to retrieve order: #{inspect(reason)}"}
      end
    end

    defp format_order(order) do
      """
      Order Details:
      - Order ID: #{order.order_id}
      - Status: #{order.status}
      - Items: #{format_items(order.items)}
      - Total: $#{order.total}
      - Tracking: #{order.tracking_number || "Not yet available"}
      - Estimated Delivery: #{format_delivery(order.estimated_delivery)}
      """
    end

    defp format_items(items) do
      items
      |> Enum.map(fn item -> "#{item.name} (x#{item.quantity})" end)
      |> Enum.join(", ")
    end

    defp format_delivery(nil), do: "Not yet calculated"
    defp format_delivery(date), do: Date.to_string(date)
  end
end
