# Claudio 0.7 gaps for Normandy 2.0

Checked 2026-10-04 against ../claudio at 5f0af38; row 10 rechecked 2026-10-05 at 230e312.

| Need | Claudio | Status |
|---|---|---|
| stop_reason :pause_turn, :refusal, :max_tokens, :compaction parsed | lib/claudio/messages/response.ex:806-814 `parse_stop_reason/1` (also :model_context_window_exceeded; unknown strings pass through) | ok |
| output_config.format together with tools | request.ex:1420 `set_output_format/2` + `add_tool/3` (test/llm/claudio_request_capabilities_test.exs, passes) | ok |
| assistant blocks sent back byte-equal (thinking, mcp_tool_use, text) | request.ex:163 `add_message/3` (test passes); also auto-adds betas for fallback/compaction/advisor replay | ok |
| mcp_tool_result / compaction / fallback blocks replayed | compaction + fallback: add_message/3 beta handling (request.ex:170-191). mcp_tool_use / mcp_tool_result: `Response.to_assistant_content/1` (response.ex:688-698) drops `server_name` and a null `is_error` (the API rejects both); tests response_test.exs:331, :1508 and live release_audit_integration_test.exs:23. Fixed in 230e312: add_message/3 now declares `mcp-client-2025-11-20` for replayed MCP blocks (without it a turn lacking add_mcp_server/2 got a 400, probed live 2026-10-05) | ok (fixed in 0.7.0) |
| streaming message_delta carries stop_reason and usage | lib/claudio/messages/stream.ex:518-531 (accumulator), :210-217 and :340-350 (telemetry) | ok |
| per-call request headers on Messages | Messages.create/2 (messages.ex:148) takes a Req.Request client and no options; a typed per-call option does not exist. Workaround: `Req.Request.put_header(client, name, value)` before the call. Verified: with_betas (client.ex:177-194) only rewrites anthropic-beta; test "a per-call header ... survives with_betas and retry" in claudio_request_capabilities_test.exs sees the header on both attempts of a 529-then-200 sequence. a9dff4b is A2A-only. | workaround exists; gap only if a typed per-call option is wanted |
| a conversation built in linear time | `Request.add_messages/2` (Claudio 0.7.1, `4125bf5`); `ClaudioAdapter.add_messages/3` makes one call (Task 7.5b, `test/llm/claudio_adapter_add_messages_test.exs`) | ok (0.7.1) |
| citations replayed on text blocks | `Response.to_assistant_content/1` emits a non-empty `citations` list (Claudio 0.7.1, `fa321a3`, Task 7.5a); Normandy test `test/agents/assistant_turn_replay_test.exs` on run/3, stream/3, Turn.Server; live check scenario 16 part B (Task 7.6a/7.6b) | ok (0.7.1) |

Not a hard gap: per-call headers (e.g. traceparent) work by building the Req client per call with Req.Request.put_header (verified above, including Req retry). A typed `:headers` option on create/stream would only be an ergonomic addition. Q (2026-10-05): add it only if needed; nothing in Normandy or the plan needs it, so no Claudio change. mcp_tool_result replay is tested in Claudio, and since 230e312 the MCP beta is declared automatically on replay, so Task 5.3 needs no workaround.
