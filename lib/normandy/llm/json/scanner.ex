defmodule Normandy.LLM.Json.Scanner do
  @moduledoc """
  Byte-scanner recovery for a single JSON truncation failure mode:
  an unclosed top-level string at depth 1 (e.g. a vision worker's `page_text`
  payload that exhausts max_tokens mid-string). Pure; zero dependencies.
  """

  @doc """
  Attempt to recover a truncated payload. Returns `{:ok, recovered_string}`
  when the failure matches "unclosed top-level string at depth 1", else `:error`.
  """
  @spec recover_truncated_string(binary()) :: {:ok, binary()} | :error
  def recover_truncated_string(content) when is_binary(content) do
    case scan(content, 0, [], false, false, nil, nil) do
      {:unclosed_top_level_string, safe_until, stack}
      when is_integer(safe_until) and stack != [] ->
        prefix = binary_part(content, 0, safe_until)
        {:ok, prefix <> "\"" <> build_closers(stack)}

      _ ->
        :error
    end
  end

  # scan(rest, pos, stack, in_string?, escape_pending?, opener_depth, safe_until)
  #
  # stack head = innermost open container. List head close char closes the
  # innermost open first — exactly the order JSON needs.
  #
  # escape_pending? is true for exactly one byte: the byte immediately after a
  # \ inside a string. That byte is consumed unconditionally.
  #
  # safe_until is updated only inside the string opened at depth 1, and only
  # for characters that are not part of a \n escape sequence. It marks the
  # byte position just past the last "safe to truncate after" character.

  # EOF inside an unclosed string at depth-1 opener with at least one safe
  # boundary recorded → recovery possible.
  defp scan(<<>>, _pos, stack, true, _esc, 1, safe_until)
       when is_integer(safe_until) and stack != [] do
    {:unclosed_top_level_string, safe_until, stack}
  end

  # EOF in any other state → no recovery.
  defp scan(<<>>, _pos, _stack, _in_string, _esc, _opener_depth, _safe_until) do
    :no_recovery
  end

  # Inside string, escape pending: consume the escaped byte. If it is "n" (or
  # "r"), it is part of a runaway sequence — do NOT advance safe_until. For
  # every other escape (\" \\ \t \b \f \/ \uXXXX), the escape represents a
  # legitimate character — advance safe_until past the two bytes.
  defp scan(<<byte, rest::binary>>, pos, stack, true, true, opener_depth, safe_until) do
    new_safe_until =
      cond do
        opener_depth != 1 -> safe_until
        byte == ?n or byte == ?r -> safe_until
        true -> pos + 1
      end

    scan(rest, pos + 1, stack, true, false, opener_depth, new_safe_until)
  end

  # Inside string, backslash starts an escape — next byte handled by the
  # escape_pending? clause above.
  defp scan(<<?\\, rest::binary>>, pos, stack, true, false, opener_depth, safe_until) do
    scan(rest, pos + 1, stack, true, true, opener_depth, safe_until)
  end

  # Inside string, closing unescaped quote: exit string, reset opener tracking.
  defp scan(<<?", rest::binary>>, pos, stack, true, false, _opener_depth, _safe_until) do
    scan(rest, pos + 1, stack, false, false, nil, nil)
  end

  # Inside string, any other byte (including literal \n, \r — which JSON
  # technically forbids unescaped, but we don't reject; the surrounding decode
  # will). Advance safe_until only at depth 1.
  defp scan(<<_byte, rest::binary>>, pos, stack, true, false, opener_depth, safe_until) do
    new_safe_until = if opener_depth == 1, do: pos + 1, else: safe_until
    scan(rest, pos + 1, stack, true, false, opener_depth, new_safe_until)
  end

  # Outside string, opening quote: enter string. opener_depth = current stack
  # depth. Initialize safe_until at the byte AFTER the opener so an immediately
  # truncated empty string `{"k": "` recovers to {"k": ""}.
  defp scan(<<?", rest::binary>>, pos, stack, false, _esc, _opener_depth, _safe_until) do
    depth = length(stack)
    initial_safe_until = if depth == 1, do: pos + 1, else: nil
    scan(rest, pos + 1, stack, true, false, depth, initial_safe_until)
  end

  # Outside string, object/array openers push onto the stack.
  defp scan(<<?{, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until) do
    scan(rest, pos + 1, [:object | stack], false, false, opener_depth, safe_until)
  end

  defp scan(<<?[, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until) do
    scan(rest, pos + 1, [:array | stack], false, false, opener_depth, safe_until)
  end

  # Outside string, matching closers pop the stack. Mismatches fall through to
  # the catch-all below, which keeps walking; the surrounding decode will have
  # already failed for the right reason if the input is malformed in a way the
  # scanner can't help with.
  defp scan(<<?}, rest::binary>>, pos, [:object | tail], false, _esc, opener_depth, safe_until) do
    scan(rest, pos + 1, tail, false, false, opener_depth, safe_until)
  end

  defp scan(<<?], rest::binary>>, pos, [:array | tail], false, _esc, opener_depth, safe_until) do
    scan(rest, pos + 1, tail, false, false, opener_depth, safe_until)
  end

  # Outside string, any other byte (whitespace, structural chars like : , ,
  # mismatched closers): walk on. We don't validate structure; that's the
  # adapter's job. We only need enough state to know "are we inside a top-level
  # string at EOF, and where's the last safe byte."
  defp scan(<<_byte, rest::binary>>, pos, stack, false, _esc, opener_depth, safe_until) do
    scan(rest, pos + 1, stack, false, false, opener_depth, safe_until)
  end

  # Build the closer string for a stack. Head of stack = innermost open =
  # closes first.
  defp build_closers(stack) do
    stack
    |> Enum.map(fn
      :object -> "}"
      :array -> "]"
    end)
    |> Enum.join()
  end
end
