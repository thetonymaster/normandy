# Turn.Server keeps hooks out of the handler set

`BaseAgent` layers the `before_llm` and `after_compact` hooks onto its handler set (`Normandy.Hooks.Handlers.wrap/2`); `Turn.Server` does not, and calls them itself in the worker, apart from `call_llm` and `compact` (`worker_hook/3`). We keep it that way so a durable turn can tell a hook's crash or halt (`{:handler_crashed, :before_llm, e}`, `{:hook_halted, e}`) from a crash in the client or compactor: `Turn.Server.run/2` never crashes and replies the cause, while `run/3` re-raises bugs and needs no such split.

## Considered Options

- **Wrap the set once for both shells**: one layering path, but a hook crash and a client crash arrive as the same raise. Telling them apart would need a tagging exception that only `Turn.Server` unwraps.
