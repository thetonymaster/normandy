# tools/api_diff

Checks that `MIGRATING-2.0.md` names every public API item a release removes or changes. Not part of
the Hex package.

```bash
tools/api_diff/run.sh main
```

It builds `main` from `git archive` in a temporary directory (`mix deps.get` there needs network or a
warm Hex cache) and the working tree with `MIX_ENV=dev mix compile`, then prints:

- `## removed_modules`, `## removed_functions` (functions, macros and callbacks, default arguments
  expanded), `## changed_specs`, `## removed_fields` (struct fields): what the working tree removed or
  changed relative to `main`. A module is public unless it is `@moduledoc false`; a function unless it
  is `@doc false`. Protocol implementations are skipped.
- `## unmatched`: the items `MIGRATING-2.0.md` does not name. Exit status 1 when there are any.

An item is named when one `## ` section of MIGRATING has a code span with the module's last alias
segment (a module), with `Last.name`, or with `name` while the section also mentions `Last` (a function,
callback or field). A fenced block counts as a code span.

When an item is covered in words the matcher cannot see, or is not a change for a caller (a spec that
only got more precise), add it to `reviewed.txt` as `<key><TAB><reason>`; the key is the item without
its kind (`Normandy.A.f/1`, `Normandy.A.field`). Otherwise write the MIGRATING text.

The pure parts (`NormandyTools.ApiDiff.diff/2`, `unmatched/3`, `parse_reviewed/1`) are tested in
`test/tools/api_diff_test.exs`.
