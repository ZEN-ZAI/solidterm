# Contributing to SolidTerm

Short version: SolidTerm is a solo project in its early phase. Drive-by PRs are welcome but may be declined if they don't fit the roadmap in `vault/ROADMAP.md`. Documentation / test / fixture contributions are the easiest to land.

## Before you start

1. Read `AGENTS.md` — conventions for humans and AI agents
2. Read `CLAUDE.md` — project orientation
3. Skim `vault/decisions/` — committed architecture decisions
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
```

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

Architectural changes go through a lightweight ADR:

1. Copy the template: `cp vault/decisions/_template.md vault/decisions/NN-your-decision.md` (where `NN` is the next chronological number — never renumber existing files)
2. Fill in title / status `proposed` / context / decision / consequences
3. Open a PR linking the new decision
4. Once merged, update status to `decided`

## Proposing a change

For code / spec changes:

1. Branch (or work on `main` for <30 min / <300 LoC per AGENTS.md #1)
2. Write tests (see `spec/testing-strategy.md`)
3. Verify locally: `cargo fmt --check && cargo clippy --workspace -- -D warnings && cargo test --workspace`
4. Open a PR using `.github/pull_request_template.md`
5. CI must pass; human review required for files listed in `CODEOWNERS`

## Scope

See `vault/ROADMAP.md` for phase scope. In short:

- **Phase 0** (now): scaffold, Metal spike
- **Phase 1** (weeks 1-16): MVP → daily-driver
- **Phase 2** (months 5-6): beta → 1.0
- **Phase 3+**: bridge, plugins, ecosystem

Features not yet in scope (e.g. Linux port, plugin marketplace) need a discussion issue + decision before implementation.

## License

License is deferred to Phase 2 (`decisions/09-mvp-scope.md`). Until then the repo is `UNLICENSED` (all rights reserved). By contributing you agree the project lead can relicense your contribution under whatever license is eventually chosen — likely MIT or Apache-2.0. If that's a blocker, open an issue before contributing code.

## Conduct

Be kind. Don't be clever at others' expense. Assume good intent.

## Questions

Open a GitHub discussion or file an issue tagged `question`.
