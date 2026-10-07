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

  def create_table!(name, attrs, type, copies, nodes) do
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, type}, {copies, nodes}]) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^name}} ->
        check_layout!(name, attrs, type)

      {:aborted, reason} ->
        raise "Mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end

  # An existing table is used only when its layout is the one asked for: a table of
  # another layout (an older Normandy's) would be read and written as if it matched.
  defp check_layout!(name, attrs, type) do
    case {:mnesia.table_info(name, :attributes), :mnesia.table_info(name, :type)} do
      {^attrs, ^type} ->
        :ok

      {got_attrs, got_type} ->
        raise "Mnesia table #{inspect(name)} exists with attributes #{inspect(got_attrs)} " <>
                "and type #{inspect(got_type)}; expected #{inspect(attrs)} and " <>
                "#{inspect(type)}. Delete the table or use another table name."
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
