defmodule CustomerSupport.DataStore.KnowledgeBase do
  @moduledoc """
  ETS-backed knowledge base for storing FAQs, documentation, and troubleshooting guides.

  Provides search functionality to find relevant articles based on queries and categories.
  """

  use GenServer
  require Logger

  @table_name :knowledge_base

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Search the knowledge base for relevant articles.
  """
  def search(query, category \\ nil) do
    query_lower = String.downcase(query)

    results =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_key, article} -> article end)
      |> filter_by_category(category)
      |> Enum.filter(fn article -> matches_query?(article, query_lower) end)
      |> Enum.sort_by(fn article -> relevance_score(article, query_lower) end, :desc)

    {:ok, results}
  rescue
    error ->
      {:error, error}
  end

  @doc """
  Get article by ID.
  """
  def get_article(article_id) do
    case :ets.lookup(@table_name, article_id) do
      [{^article_id, article}] -> {:ok, article}
      [] -> {:error, :not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    seed_knowledge_base()
    Logger.info("KnowledgeBase initialized with sample articles")
    {:ok, %{table: table}}
  end

  # Private Functions

  defp filter_by_category(articles, nil), do: articles

  defp filter_by_category(articles, category) do
    Enum.filter(articles, fn article -> article.category == category end)
  end

  defp matches_query?(article, query) do
    searchable_text =
      "#{String.downcase(article.title)} #{String.downcase(article.content)} #{article.tags |> Enum.join(" ") |> String.downcase()}"

    String.contains?(searchable_text, query)
  end

  defp relevance_score(article, query) do
    title_match = if String.contains?(String.downcase(article.title), query), do: 10, else: 0
    content_match = count_occurrences(String.downcase(article.content), query)
    title_match + content_match
  end

  defp count_occurrences(text, query) do
    text
    |> String.split(query)
    |> length()
    |> Kernel.-(1)
  end

  defp seed_knowledge_base do
    articles = [
      %{
        id: "kb-001",
        title: "How to Track Your Order",
        category: "shipping",
        content: """
        To track your order, you'll need your order ID (format: ORD-XXXXX).
        Once your order ships, you'll receive a tracking number via email.
        Typical delivery times are 3-7 business days for standard shipping.
        """,
        tags: ["tracking", "shipping", "delivery", "order status"]
      },
      %{
        id: "kb-002",
        title: "Return and Refund Policy",
        category: "returns",
        content: """
        We accept returns within 30 days of purchase. Items must be in original condition.
        Refunds are processed within 3-5 business days after we receive your return.
        Original shipping costs are non-refundable unless the item is defective.
        """,
        tags: ["returns", "refund", "policy", "money back"]
      },
      %{
        id: "kb-003",
        title: "Product Not Working - Troubleshooting",
        category: "technical",
        content: """
        If your product isn't working:
        1. Check that it's properly powered on and charged
        2. Ensure all cables are securely connected
        3. Try resetting the device by holding the power button for 10 seconds
        4. Check for firmware updates in the product manual
        If issues persist, contact support for replacement or repair.
        """,
        tags: ["troubleshooting", "not working", "broken", "technical support"]
      },
      %{
        id: "kb-004",
        title: "How to Update Billing Information",
        category: "billing",
        content: """
        To update your billing information:
        1. Log into your account at techstore.com
        2. Navigate to Account Settings > Payment Methods
        3. Add a new payment method or update existing one
        4. Save your changes
        Your new payment method will be used for future orders.
        """,
        tags: ["billing", "payment", "credit card", "account"]
      },
      %{
        id: "kb-005",
        title: "Warranty Information",
        category: "general",
        content: """
        All products come with a 1-year manufacturer warranty covering defects.
        Extended warranties are available for purchase within 30 days of buying.
        Warranty does not cover accidental damage or normal wear and tear.
        To file a warranty claim, contact support with your order ID and photos.
        """,
        tags: ["warranty", "guarantee", "coverage", "protection"]
      },
      %{
        id: "kb-006",
        title: "Shipping Costs and Options",
        category: "shipping",
        content: """
        Shipping options:
        - Standard (5-7 days): $5.99
        - Express (2-3 days): $12.99
        - Overnight: $24.99
        Free shipping on orders over $50.
        International shipping available to select countries.
        """,
        tags: ["shipping", "cost", "delivery", "international"]
      },
      %{
        id: "kb-007",
        title: "Product Compatibility Guide",
        category: "technical",
        content: """
        Before purchasing, check product compatibility:
        - USB-C devices require USB-C ports (check your device specs)
        - Wireless products use Bluetooth 5.0 (works with 4.0+ devices)
        - Power adapters are region-specific (US, EU, UK, AU)
        Contact support if you're unsure about compatibility.
        """,
        tags: ["compatibility", "works with", "requirements", "specs"]
      },
      %{
        id: "kb-008",
        title: "Order Cancellation Policy",
        category: "general",
        content: """
        Orders can be cancelled within 24 hours of placement if not yet shipped.
        Once shipped, orders cannot be cancelled but can be returned.
        To cancel an order, contact support immediately with your order ID.
        Refunds for cancelled orders are processed within 3-5 business days.
        """,
        tags: ["cancel", "cancellation", "stop order"]
      }
    ]

    Enum.each(articles, fn article ->
      :ets.insert(@table_name, {article.id, article})
    end)
  end
end
