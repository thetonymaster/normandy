defmodule CustomerSupport.DataStore.OrderStore do
  @moduledoc """
  ETS-backed order database for customer support operations.

  Stores and retrieves order information including status, items,
  tracking, and delivery details.
  """

  use GenServer
  require Logger

  @table_name :orders

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get order by ID.
  """
  def get_order(order_id) do
    case :ets.lookup(@table_name, order_id) do
      [{^order_id, order}] -> {:ok, order}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Update order status.
  """
  def update_order_status(order_id, new_status) do
    case get_order(order_id) do
      {:ok, order} ->
        updated_order = Map.put(order, :status, new_status)
        :ets.insert(@table_name, {order_id, updated_order})
        {:ok, updated_order}

      error ->
        error
    end
  end

  @doc """
  List all orders (for admin/testing purposes).
  """
  def list_orders do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_key, order} -> order end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    seed_sample_data()
    Logger.info("OrderStore initialized with sample data")
    {:ok, %{table: table}}
  end

  # Private Functions

  defp seed_sample_data do
    sample_orders = [
      %{
        order_id: "ORD-12345",
        customer_email: "customer@example.com",
        status: "shipped",
        items: [
          %{name: "Wireless Headphones", quantity: 1, price: 79.99},
          %{name: "USB-C Cable", quantity: 2, price: 12.99}
        ],
        total: 105.97,
        tracking_number: "TRK-ABC123",
        estimated_delivery: Date.add(Date.utc_today(), 3),
        created_at: DateTime.add(DateTime.utc_now(), -5, :day)
      },
      %{
        order_id: "ORD-67890",
        customer_email: "jane@example.com",
        status: "processing",
        items: [
          %{name: "Laptop Stand", quantity: 1, price: 45.00}
        ],
        total: 45.00,
        tracking_number: nil,
        estimated_delivery: Date.add(Date.utc_today(), 7),
        created_at: DateTime.add(DateTime.utc_now(), -2, :day)
      },
      %{
        order_id: "ORD-11111",
        customer_email: "customer@example.com",
        status: "delivered",
        items: [
          %{name: "Mechanical Keyboard", quantity: 1, price: 129.99}
        ],
        total: 129.99,
        tracking_number: "TRK-XYZ789",
        estimated_delivery: nil,
        created_at: DateTime.add(DateTime.utc_now(), -15, :day)
      },
      %{
        order_id: "ORD-22222",
        customer_email: "bob@example.com",
        status: "shipped",
        items: [
          %{name: "Monitor", quantity: 1, price: 299.99},
          %{name: "HDMI Cable", quantity: 1, price: 15.99}
        ],
        total: 315.98,
        tracking_number: "TRK-MON456",
        estimated_delivery: Date.add(Date.utc_today(), 2),
        created_at: DateTime.add(DateTime.utc_now(), -3, :day)
      }
    ]

    Enum.each(sample_orders, fn order ->
      :ets.insert(@table_name, {order.order_id, order})
    end)
  end
end
