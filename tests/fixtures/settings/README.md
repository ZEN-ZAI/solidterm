# settings.json fixtures

Schema validation + precedence-cascade test inputs. Schema reference: `vault/raw/cc-docs-c-settings-hosted.md`.

## Layout

| Subdir | What |
|---|---|
| `valid/` | settings.json files that should load cleanly |
| `invalid/` | files that should fail validation; each has a sibling `.error.json` documenting the expected error |
| `hierarchy/` | one file per scope (managed/user/project/local) — exercise precedence cascade |

## Adding a new sample

For valid: `valid/<name>.json`. For invalid: `invalid/<name>.json` + `invalid/<name>.error.json` matching the validator's expected output:

```json
{
  "kind": "TypeMismatch",
  "path": "permissions.defaultMode",
  "expected": "enum",
  "actual": "string \"foo\"",
  "message": "permissions.defaultMode must be one of: default, acceptEdits, plan, auto, dontAsk, bypassPermissions"
}
```

## Schema

JSON Schema lives at `~/Projects/nextterm/crates/nextterm-config/src/schema/settings-v1.json` (Phase 1 M5). Until then validation is by parser deserialization; tests assert structural correctness only.
