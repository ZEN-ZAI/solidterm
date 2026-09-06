# ADR-0005 — Keybinding grammar and resolution order

Status: accepted

## Context

App actions (open settings, new window, font size, tabs, find) need
user-rebindable shortcuts, and the bindings live in a file the user edits by
hand: `~/.solidterm/keybindings.json`. A hand-edited file arrives malformed,
half-written, or naming an action that does not exist, and it arrives with the
same chord spelled three different ways — `Cmd+Shift+W`, `shift+cmd+w`,
`cmd+shift+W`. Something has to decide what those mean, and what happens when
they disagree with each other or with the built-in defaults.

The failure mode to avoid is a terminal that will not launch because its
keybinding file has a typo in it.

## Decision

**Grammar.** A binding value is one or more *strokes* separated by single
spaces; more than one stroke is a chord (`cmd+k cmd+t`). A stroke is zero or
more modifiers and exactly one key, joined by `+`. The modifiers are `cmd`,
`ctrl`, `alt`, `shift`. The whole grammar is case-insensitive, and modifier
order inside a stroke is not significant — `KeybindingStore.normalizeKey`
lowercases and sorts modifiers into the canonical order cmd, ctrl, alt, shift,
so equality and lookup compare normalized forms. Chord separators survive
normalization.

**Resolution order.** Built-in defaults load first, the user file overlays
them. Within the file's `bindings` array the last entry for an action wins. The
`disabled` list beats `bindings`: a disabled action resolves to nothing, and
`menuKeyEquivalent` hands AppKit an empty key equivalent.

**Degradation is warn-and-continue, never a crash.** A malformed file falls
back to the defaults with a diagnostic. An unknown action string is skipped
with a diagnostic. A binding in a reserved range is skipped at load with a
diagnostic, and the settings editor refuses to save one in the first place.
Diagnostics are published off the store and surfaced as chips in
Settings → Keyboard, which is one of the discoverability surfaces for
app-action bindings alongside the menu bar and the command palette.

**Chords decode but do not dispatch.** The grammar accepts them and the store
normalizes them; runtime chord dispatch is not wired.

## Consequences

- A user who types a shortcut in whatever capitalization and modifier order
  they think in gets the binding they meant.
- A broken keybindings file costs the user their custom bindings for that
  launch and nothing else; the app starts on defaults and says why.
- Because normalization is a pure static function on the store, the canonical
  form is the same everywhere a binding is compared, stored, or handed to
  AppKit — there is no second spelling rule in the menu bridge.
- Extending the reserved ranges, or adding an action, is a change in one file;
  the file format does not change with it.
