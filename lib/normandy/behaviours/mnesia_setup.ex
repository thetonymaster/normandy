defmodule Normandy.Behaviours.MnesiaSetup do
  @moduledoc false
  # Table setup shared by SessionStore.Mnesia and MemoryStore.Mnesia.

  @compile {:no_warn_undefined, :mnesia}

  def ensure_started! do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      _ -> :mnesia.start()
    end
  end

  def ensure_disc_schema!(nodes) do
    Enum.each(nodes, fn n ->
      case :mnesia.change_table_copy_type(:schema, n, :disc_copies) do
        {:atomic, :ok} ->
          :ok

        {:aborted, {:already_exists, :schema, _, :disc_copies}} ->
          :ok

        {:aborted, reason} ->
          raise "Mnesia disc schema setup failed on #{inspect(n)}: #{inspect(reason)}"
      end
    end)
  end

  def create_table!(name, attrs, copies, nodes) do
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, :set}, {copies, nodes}]) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^name}} ->
        :ok

      {:aborted, reason} ->
        raise "Mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end

  # After a restart, disc_copies tables already exist but load in the background; a
  # transaction before they finish aborts with :no_exists.
  def wait_for_tables!(tables, timeout, label) do
    case :mnesia.wait_for_tables(tables, timeout) do
      :ok ->
        :ok

      {:timeout, tables} ->
        raise "#{label}: tables not loaded within the wait timeout: #{inspect(tables)}"

      {:error, reason} ->
        raise "#{label}: waiting for tables failed: #{inspect(reason)}"
    end
  end
end
