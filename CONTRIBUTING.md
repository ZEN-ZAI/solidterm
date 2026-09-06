# Contributing to SolidTerm

Short version: SolidTerm is a solo project in its early phase. Drive-by PRs are welcome but may be declined if they don't fit what's planned in `.scratch/` (see `docs/agents/issue-tracker.md`). Documentation / test / fixture contributions are the easiest to land.

## Before you start

1. Read `AGENTS.md` — conventions for humans and AI agents
2. Read `CLAUDE.md` — project orientation
3. Skim `docs/adr/` — committed architecture decisions
4. For non-trivial changes, open an issue first to sanity-check the approach

## Setup

```bash
# Rust toolchain (pinned via rust-toolchain.toml)
rustup show

# Build + check
cargo check --workspace
cargo test --workspace

# Install git hooks (AGENTS.md stop-the-line rules)
./scripts/install-hooks.sh

# Skip the tree-wide swift-format commit in `git blame`
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

`.git-blame-ignore-revs` lists mechanical, semantics-free reformats. Without that
config line every Swift line blames to the reformat instead of to the commit that
wrote it; add a revision to the file whenever another tree-wide pass lands.

Note: the locally-resolved `xcrun swift-format` can be a different version from CI's and may flag pre-existing lines your change didn't touch — if the pre-commit lint blocks on untouched code, rely on the CI lint as the source of truth.

For Swift changes:

```bash
xcodebuild build -scheme SolidTerm -destination 'platform=macOS'
xcodebuild test  -scheme SolidTerm -destination 'platform=macOS'
```

## Xcode project

`app/SolidTerm.xcodeproj` is generated from `app/project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). The YAML is the source of truth; the generated `.xcodeproj` is committed so a fresh clone (or CI) builds without needing XcodeGen on the path.

```bash
brew install xcodegen           # one-time setup
./scripts/regen-xcodeproj.sh    # after any edit to app/project.yml
```

Commit the regenerated `.xcodeproj` in the **same commit** as the YAML change so reviewers can see the effective diff. Direct edits to `project.pbxproj` are wiped on the next regeneration; if you need a setting XcodeGen doesn't expose, raise it in the YAML or open an issue.

## Proposing a decision

Architectural changes go through a lightweight ADR in `docs/adr/` (format per `docs/agents/domain.md`):

1. Add `docs/adr/NNNN-your-decision.md`, where `NNNN` is the next chronological number — never renumber existing files
2. Fill in title / status `proposed` / context / decision / consequences
3. Open a PR linking the new ADR
4. Once merged, update status to `accepted`

## Proposing a change

For code / spec changes:

1. Branch (or work on `main` for <30 min / <300 LoC per AGENTS.md #1)
2. Write tests (unit / integration / smoke — see `crates/solidterm-engine/tests/` and `app/SolidTermTests/`)
3. Verify locally: `cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace`
4. Open a PR using `.github/pull_request_template.md`
5. CI must pass; human review required for files listed in `CODEOWNERS`

## Scope

Planned work lives in `.scratch/<feature-slug>/` — one spec plus one file per ticket, per `docs/agents/issue-tracker.md`. `CLAUDE.md` lists what SolidTerm covers today.

Features not yet in scope (e.g. Linux port, plugin marketplace) need a discussion issue + decision before implementation.

## License

SolidTerm is licensed under GPL-3.0-or-later (see `LICENSE`). Contributions are accepted under the same license, and by contributing you grant the maintainer the right to relicense your contribution.

## Conduct

Be kind. Don't be clever at others' expense. Assume good intent.

## Questions

Open a GitHub discussion or file an issue tagged `question`.
