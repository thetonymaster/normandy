defmodule CustomerSupport.CLI do
  @moduledoc """
  Command-line interface for the Customer Support application.

  Provides an interactive REPL for testing the customer support system.

  ## Usage

      # From the project root
      iex -S mix

      # Start a chat session
      CustomerSupport.CLI.start()

      # Or run directly
      mix run -e "CustomerSupport.CLI.start()"
  """

  require Logger

  @commands """

  Available commands:
    /help     - Show this help message
    /history  - Show conversation history
    /stats    - Show session statistics
    /clear    - Clear screen
    /quit     - End session and exit

  Just type your message to chat with support.
  """

  def start do
    print_banner()

    case Application.ensure_all_started(:customer_support) do
      {:ok, _} ->
        Logger.info("Application started successfully")
        run_chat_loop()

      {:error, reason} ->
        IO.puts("Failed to start application: #{inspect(reason)}")
        IO.puts("Make sure ANTHROPIC_API_KEY environment variable is set.")
    end
  end

  defp run_chat_loop do
    case CustomerSupport.create_session() do
      {:ok, session_id} ->
        IO.puts("\n✓ Connected to support (Session: #{session_id})")
        IO.puts("Type /help for available commands\n")

        chat_loop(session_id)

      {:error, reason} ->
        IO.puts("Failed to create session: #{inspect(reason)}")
    end
  end

  defp chat_loop(session_id) do
    prompt = IO.ANSI.green() <> "You: " <> IO.ANSI.reset()
    input = IO.gets(prompt) |> String.trim()

    case input do
      "" ->
        chat_loop(session_id)

      "/quit" ->
        CustomerSupport.end_session(session_id)
        IO.puts("\n✓ Session ended. Thank you for contacting TechStore support!\n")
        :ok

      "/help" ->
        IO.puts(@commands)
        chat_loop(session_id)

      "/history" ->
        show_history(session_id)
        chat_loop(session_id)

      "/stats" ->
        show_stats(session_id)
        chat_loop(session_id)

      "/clear" ->
        IO.write(IO.ANSI.clear() <> IO.ANSI.home())
        print_banner()
        chat_loop(session_id)

      message ->
        send_and_display(session_id, message)
        chat_loop(session_id)
    end
  end

  defp send_and_display(session_id, message) do
    IO.write(IO.ANSI.cyan() <> "Agent: " <> IO.ANSI.reset())
    IO.write("(thinking...)")

    case CustomerSupport.send_message(session_id, message) do
      {:ok, response} ->
        # Clear the "thinking..." message
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.cyan() <> "Agent: " <> IO.ANSI.reset() <> response)
        IO.puts("")

      {:error, reason} ->
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.red() <> "Error: #{inspect(reason)}" <> IO.ANSI.reset())
        IO.puts("")
    end
  end

  defp show_history(session_id) do
    case CustomerSupport.get_history(session_id) do
      {:ok, history} ->
        IO.puts("\n" <> IO.ANSI.yellow() <> "=== Conversation History ===" <> IO.ANSI.reset())

        if Enum.empty?(history) do
          IO.puts("No messages yet.")
        else
          Enum.each(history, fn entry ->
            timestamp = format_timestamp(entry.timestamp)
            role = format_role(entry.role, Map.get(entry, :agent))

            IO.puts("\n#{timestamp} #{role}")
            IO.puts("  #{entry.content}")
          end)
        end

        IO.puts("\n" <> IO.ANSI.yellow() <> "========================" <> IO.ANSI.reset() <> "\n")

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "Error fetching history: #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end

  defp show_stats(session_id) do
    case CustomerSupport.get_history(session_id) do
      {:ok, history} ->
        user_messages = Enum.count(history, &(&1.role == :user))
        assistant_messages = Enum.count(history, &(&1.role == :assistant))

        agents_used =
          history
          |> Enum.filter(&(&1.role == :assistant))
          |> Enum.map(&Map.get(&1, :agent))
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)

        IO.puts("\n" <> IO.ANSI.yellow() <> "=== Session Statistics ===" <> IO.ANSI.reset())
        IO.puts("Session ID: #{session_id}")
        IO.puts("User messages: #{user_messages}")
        IO.puts("Agent messages: #{assistant_messages}")
        IO.puts("Agents used: #{Enum.join(agents_used, ", ")}")
        IO.puts(IO.ANSI.yellow() <> "========================" <> IO.ANSI.reset() <> "\n")

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "Error fetching stats: #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end

  defp format_timestamp(timestamp) do
    "#{timestamp.hour |> to_string() |> String.pad_leading(2, "0")}:" <>
      "#{timestamp.minute |> to_string() |> String.pad_leading(2, "0")}:" <>
      "#{timestamp.second |> to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_role(:user, _), do: IO.ANSI.green() <> "[You]" <> IO.ANSI.reset()

  defp format_role(:assistant, agent) do
    agent_name =
      case agent do
        :greeter -> "Greeter"
        :order_support -> "Order Support"
        :technical_support -> "Technical Support"
        :billing_support -> "Billing Support"
        _ -> "Agent"
      end

    IO.ANSI.cyan() <> "[#{agent_name}]" <> IO.ANSI.reset()
  end

  defp print_banner do
    IO.puts("""

    #{IO.ANSI.cyan()}╔═══════════════════════════════════════════════╗
    ║                                               ║
    ║     TechStore Customer Support System         ║
    ║     Powered by Normandy AI Agents             ║
    ║                                               ║
    ╚═══════════════════════════════════════════════╝#{IO.ANSI.reset()}

    Welcome to TechStore support! Our AI agents are here to help.
    """)
  end
end
