# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## No glossary

This repo has no `GLOSSARY.md` and does not want one. Don't create it, don't suggest it, and don't flag its absence, including from `/domain-modeling`, `/grill-with-docs` and `/improve-codebase-architecture`. Record a resolved term where the code already explains itself: the module's `@moduledoc` or the Architecture section of `CLAUDE.md`.

Domain vocabulary comes from `CLAUDE.md` (Architecture) and the module names and `@moduledoc`s under `lib/`. When your output names a domain concept (an issue title, a refactor proposal, a hypothesis, a test name), use the term as those name it.

## Before exploring, read these

- **`docs/adr/`** at the repo root: read ADRs that touch the area you're about to work in.

If `docs/adr/` doesn't exist, **proceed silently**. `/domain-modeling` creates it lazily when a decision actually gets resolved.

## File structure

```
/
├── CLAUDE.md
├── docs/adr/
│   └── 0001-<decision>.md
└── lib/
```

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
