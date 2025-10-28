defmodule CustomerSupport.Agents.GreeterAgent do
  @moduledoc """
  Initial triage agent that greets customers and determines their needs.

  This agent performs the first interaction with customers, gathering
  information about their query type to route to the appropriate specialist.
  """

  use Normandy.DSL.Agent

  alias CustomerSupport.Tools.KnowledgeBaseTool

  agent do
    model("claude-3-5-sonnet-20241022")
    temperature(0.7)

    background("""
    You are a friendly customer service greeter for TechStore, an online electronics retailer.
    Your role is to:
    1. Warmly welcome customers
    2. Understand the nature of their inquiry
    3. Determine which type of support they need:
       - ORDER: Questions about orders, shipping, tracking
       - TECHNICAL: Product issues, troubleshooting, compatibility
       - BILLING: Payment, refunds, account issues
       - GENERAL: Other questions, policies, information

    You have access to a knowledge base for quick answers to common questions.
    """)

    steps("""
    1. Greet the customer warmly and professionally
    2. Ask what they need help with if not immediately clear
    3. Search the knowledge base for simple queries that can be answered immediately
    4. For complex issues, classify the query type (ORDER/TECHNICAL/BILLING/GENERAL)
    5. Provide any immediate helpful information
    6. Let them know you're connecting them to a specialist if needed
    """)

    output_instructions("""
    - Be warm, friendly, and empathetic
    - Use clear, conversational language
    - Keep responses concise (2-3 sentences for greetings)
    - If answering from knowledge base, provide complete information
    - Always end by asking if there's anything else you can help with
    - Include the query classification in your response for routing
    """)

    tool(KnowledgeBaseTool)
  end

  @doc """
  Classify the customer query type for routing.
  """
  def classify_query(message) do
    message_lower = String.downcase(message)

    cond do
      matches_keywords?(message_lower, ["order", "shipping", "track", "delivery", "package"]) ->
        :order

      matches_keywords?(message_lower, [
        "not working",
        "broken",
        "technical",
        "issue",
        "problem",
        "compatible"
      ]) ->
        :technical

      matches_keywords?(message_lower, ["refund", "payment", "charge", "billing", "cancel"]) ->
        :billing

      true ->
        :general
    end
  end

  defp matches_keywords?(text, keywords) do
    Enum.any?(keywords, fn keyword -> String.contains?(text, keyword) end)
  end
end
