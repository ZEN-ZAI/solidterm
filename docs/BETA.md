# NextTerm Beta — invitee guide

Welcome. NextTerm is a native macOS terminal with deep Claude Code integration. You're one of 3-5 invited beta testers helping us close Phase 1 → 1.0.

## Install (~2 min)

The beta DMG is **unsigned** — Apple Developer ID code-signing + notarization land in Phase 2 (the 1.0 release). For beta you'll see a one-time Gatekeeper warning.

1. Download `NextTerm-1.0.0-beta1.dmg` from the link the maintainer shares.
2. Open the DMG → drag `NextTerm.app` to `/Applications`.
3. Eject the DMG.
4. **First launch only**: Finder → `/Applications` → right-click `NextTerm.app` → **Open** → confirm in the Gatekeeper dialog. Apple's "developer cannot be verified" warning is expected for unsigned builds.
5. After the first launch, NextTerm opens like any app (double-click works thereafter).

If Gatekeeper doesn't offer the **Open** option:
1. System Settings → Privacy & Security → scroll to "NextTerm.app was blocked" → **Open Anyway**.
2. Re-launch and confirm.

## Version check

```sh
defaults read /Applications/NextTerm.app/Contents/Info.plist CFBundleShortVersionString
```

Should read `1.0.0-beta1` (or whatever beta tag the invite mentioned).

## What to test

NextTerm shipped Phase 1 in 16 days; please stress-test the daily-driver experience:

**Daily shell work**
- Run as your primary terminal for at least a week
- Usual workflows: git, builds, vim/nvim, less/man, htop/btop
- IME if you use one (Thai, CJK, Dictation)

**Claude Code integration**
- Run `claude` to launch the Claude Code CLI in a NextTerm pane
- Paste large prompts, run long sessions, observe scrollback + permission prompts
- Try the right sidebar (`setTeamSidebarVisible(true)` from the Settings → for now wired automatically when you spawn a `claude` session)

**M6 features**
- **⌘K** opens command palette
- **⌘B** toggles left sidebar (Sessions / Hooks / Library)
- **⌘[ / ⌘]** jump between command blocks
- **⌘+click** on a file path in output → opens in your default editor (configurable in Settings → Appearance)
- **Theme picker** in Settings → Appearance — try Light, Dark, System; report any contrast issues
- **Keybindings** in Settings → Keybindings — rebind anything you don't like

**Edge cases worth probing**
- Resize window mid-session (tests cell-grid + gutter math)
- Long paste (multi-MB) into a shell command
- `clear` followed by typing — should appear instantly (regression we caught at M5.5)
- Hooks: `~/.claude/settings.json` editor in Settings → Hooks tab

## What's deferred to 1.0

Documented so you don't waste time reporting these:

- **No code-signing yet** (Phase 2). Gatekeeper warning on first launch is expected.
- **No auto-update** (Phase 2). You'll get future betas via direct download links.
- **No localization** beyond English (Phase 2). Thai+English coming in Phase 2.
- **No SGR faint/bold/inverse rendering** (B11 backlog) — `\e[2m` etc. render as plain text. zsh-autosuggestions look identical to typed text unless you set an explicit `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE`.
- **No tabs yet** (Phase 2 / M7+). One window = one shell + optional teammate panes.
- **No homebrew formula** (Phase 2). DMG is the only install path right now.

## How to file feedback

Two channels:

**Bug reports** → `.github/ISSUE_TEMPLATE/bug_report.md` template — for things that crash, render wrong, or block your workflow.

**General feedback** → `.github/ISSUE_TEMPLATE/beta_feedback.md` template — for "this is annoying", "I wish it did X", "the cursor blink is too fast", anything qualitative.

Either way: use GitHub Issues on the repo (the maintainer will share the URL with the invite) **OR** email the maintainer directly if you'd rather not file publicly.

## Privacy

NextTerm is **zero-telemetry by design** (per `decisions/03-telemetry.md`). The app does not phone home. The maintainer only sees what you choose to share via issues / email.

## Logs (if you need them for a bug report)

```sh
log stream --process NextTerm --info
```

Run that in a separate Terminal.app (not NextTerm itself) while reproducing the bug, then attach the relevant lines to the issue. Redact anything that looks like a credential.

## Thanks

Phase 1 wasn't possible without the prior research — and Phase 1 → 1.0 isn't possible without your eyes on it. Honest feedback wins, including "this is unusable" if that turns out to be true.

— Zen
