//! CLAUDE.md cascade resolver — produces a single merged text plus
//! per-byte provenance spans for the merged-viewer (M5-5).
//!
//! # Cascade order
//!
//! Per Claude Code's documented cascade behavior
//! (<https://code.claude.com/docs/en/memory>): files are concatenated,
//! never overriding. The viewer mirrors that ordering so the merged
//! preview matches what Claude Code itself loads:
//!
//! 1. **User-global** — `~/.claude/CLAUDE.md` (separate from the
//!    directory walk; loaded first as the broadest scope).
//! 2. **Directory walk from filesystem root → CWD** — at each ancestor
//!    directory, in root-down order, the resolver picks up:
//!    - `<dir>/CLAUDE.md`
//!    - `<dir>/CLAUDE.local.md` (appended after CLAUDE.md per
//!      the docs: "your personal notes are the last thing Claude
//!      reads at that level")
//! 3. **Project `.claude/CLAUDE.md`** — at the working directory only,
//!    `<cwd>/.claude/CLAUDE.md` is also picked up if present, after
//!    the working-dir's `<cwd>/CLAUDE.md` and before its
//!    `CLAUDE.local.md`.
//!
//! # `@import` handling
//!
//! `@path/to/file.md` syntax expands inline. Per the docs:
//! - Both relative and absolute paths are allowed.
//! - Relative paths resolve against the file containing the import,
//!   not the working directory.
//! - Maximum import depth is **5 hops** (matches the canonical Claude
//!   Code reference; the brief delegated this choice — picking 5 over
//!   the brief's "8 reasonable" suggestion to stay byte-for-byte
//!   consistent with what Claude Code itself does).
//!
//! Imports beyond depth 5, cycle-completing imports, and missing
//! files all emit a synthetic comment line in the merged text:
//!
//! ```text
//! <!-- solidterm: missing import at <absolute path> -->
//! <!-- solidterm: import depth exceeded for <absolute path> -->
//! <!-- solidterm: import cycle skipped for <absolute path> -->
//! ```
//!
//! The synthetic line is attributed (via [`ProvenanceSpan`]) to the
//! file that issued the import, so the gutter highlights the parent's
//! color band — matching the user's mental model that the import
//! belongs to its enclosing file.
//!
//! # HTML-comment stripping
//!
//! The Claude Code docs note: "Block-level HTML comments
//! (`<!-- maintainer notes -->`) in CLAUDE.md files are stripped
//! before the content is injected into Claude's context. Use them to
//! leave notes for human maintainers without spending context tokens
//! on them. Comments inside code blocks are preserved."
//!
//! For the viewer we **preserve** these comments (the user is
//! actively previewing what's on disk; stripping would surprise
//! them). The comments stay in the merged text and remain
//! attributable; a future visual filter can hide them in the UI.
//! This deviation is documented here rather than silently mismatching
//! Claude Code semantics.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Maximum recursion depth for `@import` directives. Matches the
/// Claude Code reference (`code.claude.com/docs/en/memory`) so the
/// merged preview stays byte-for-byte consistent with what the upstream
/// agent loads.
pub const MAX_IMPORT_DEPTH: u8 = 5;

/// One contiguous byte range in the merged text attributed to a
/// single source file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProvenanceSpan {
    /// Inclusive byte offset into [`MergedClaudeMd::merged_text`].
    pub byte_start: u32,
    /// Exclusive byte offset into [`MergedClaudeMd::merged_text`].
    pub byte_end: u32,
    /// Absolute path of the source file this byte range came from.
    /// For synthetic warning lines (missing / cycle / depth-exceeded)
    /// this is the path of the file that issued the failing import.
    pub source_path: PathBuf,
}

/// Result of a [`resolve`] call: the concatenated text Claude Code
/// would load, plus per-span provenance.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MergedClaudeMd {
    /// The concatenated text. Each top-level source file is followed
    /// by a single `\n` separator if its content didn't already end
    /// with one — this guarantees clean line boundaries between
    /// adjacent provenance spans.
    pub merged_text: String,
    /// Spans cover [`Self::merged_text`] byte-by-byte with no gaps.
    /// Adjacent spans may share a `source_path` (when an `@import`
    /// re-enters the same file's textual flow after a nested import
    /// completes).
    pub spans: Vec<ProvenanceSpan>,
}

/// Resolve the CLAUDE.md cascade rooted at `working_dir`. `home_dir`
/// is the user's home directory (used to find `~/.claude/CLAUDE.md`);
/// pass `None` to skip the user-global scope (useful for tests).
///
/// Always returns successfully — missing files are surfaced as
/// synthetic comment lines in the merged text rather than errors.
/// Callers display the result regardless of whether the cascade is
/// empty.
#[must_use]
pub fn resolve(working_dir: &Path, home_dir: Option<&Path>) -> MergedClaudeMd {
    let mut out = MergedClaudeMd::default();
    let mut visited: HashSet<PathBuf> = HashSet::new();

    // ── 1. User-global scope ────────────────────────────────────────
    if let Some(home) = home_dir {
        let user_global = home.join(".claude").join("CLAUDE.md");
        if user_global.is_file() {
            ingest_file(&user_global, &mut out, &mut visited, 0);
        }
    }

    // ── 2. Root-down directory walk ─────────────────────────────────
    //
    // Build the ancestor chain from filesystem root → working_dir so
    // we can iterate root-down (the docs guarantee this order: "content
    // is ordered from the filesystem root down to your working
    // directory").
    let mut ancestors: Vec<&Path> = working_dir.ancestors().collect();
    ancestors.reverse(); // now root-first

    for dir in &ancestors {
        let claude_md = dir.join("CLAUDE.md");
        if claude_md.is_file() {
            ingest_file(&claude_md, &mut out, &mut visited, 0);
        }

        // `<cwd>/.claude/CLAUDE.md` is the alternative project-instructions
        // location per the docs ("./CLAUDE.md or ./.claude/CLAUDE.md").
        // We pick it up only at the deepest level (working_dir) — that's
        // where Claude Code looks; ancestor `.claude/` directories are
        // not part of the documented cascade.
        if dir == ancestors.last().expect("ancestors non-empty: at least cwd") {
            let dot_claude = dir.join(".claude").join("CLAUDE.md");
            if dot_claude.is_file() {
                ingest_file(&dot_claude, &mut out, &mut visited, 0);
            }
        }

        let claude_local = dir.join("CLAUDE.local.md");
        if claude_local.is_file() {
            ingest_file(&claude_local, &mut out, &mut visited, 0);
        }
    }

    out
}

/// Read `path`, expand any `@import`s, and append the result to `out`
/// with provenance spans attributed to `path` (with nested imports
/// attributed to their own file).
///
/// `visited` is the cycle-detection set: the absolute path of every
/// file currently on the import stack. `depth` is the current import
/// depth (0 = top-level cascade entry; each `@import` adds 1; capped
/// at [`MAX_IMPORT_DEPTH`]).
fn ingest_file(path: &Path, out: &mut MergedClaudeMd, visited: &mut HashSet<PathBuf>, depth: u8) {
    let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());

    // Guard: already on the import stack ⇒ cycle.
    if visited.contains(&canonical) {
        emit_synthetic(
            out,
            path,
            &format!(
                "<!-- solidterm: import cycle skipped for {} -->\n",
                canonical.display()
            ),
        );
        return;
    }

    let text = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(err) => {
            tracing::warn!(?err, ?path, "claude_md: read failed; emitting synthetic");
            emit_synthetic(
                out,
                path,
                &format!("<!-- solidterm: missing import at {} -->\n", path.display()),
            );
            return;
        }
    };

    visited.insert(canonical.clone());
    expand_with_imports(&text, &canonical, out, visited, depth);
    visited.remove(&canonical);

    // Ensure clean line boundary between adjacent top-level files.
    if !out.merged_text.ends_with('\n') {
        let start = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
        out.merged_text.push('\n');
        let end = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
        // The trailing newline is attributed to the just-ingested file
        // so the visual gutter stays unbroken.
        push_span(out, start, end, path);
    }
}

/// Walk `text` line-by-line, expanding `@path` import lines inline.
/// Non-import lines append to `out.merged_text` and contribute to the
/// span attributed to `source`.
fn expand_with_imports(
    text: &str,
    source: &Path,
    out: &mut MergedClaudeMd,
    visited: &mut HashSet<PathBuf>,
    depth: u8,
) {
    // Track a "buffered" run of source-attributed bytes; flush it as a
    // single span whenever an import boundary or end-of-file arrives.
    let mut buffered_start = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
    let mut in_code_fence = false;

    let lines = text.split_inclusive('\n');
    for line in lines {
        // Toggle code-fence state on lines that start with ``` (after
        // optional leading whitespace). We only need this for the
        // import detector — code-block contents must not be parsed as
        // imports.
        if is_fence_line(line) {
            in_code_fence = !in_code_fence;
            out.merged_text.push_str(line);
            continue;
        }

        if !in_code_fence {
            if let Some(import_target) = parse_import_line(line) {
                // Flush the source-attributed buffer up to this point.
                let here = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
                if here > buffered_start {
                    push_span(out, buffered_start, here, source);
                }

                // Resolve the import target and recurse.
                resolve_import(&import_target, source, out, visited, depth);

                // Reset the buffer to start from the post-import cursor.
                buffered_start = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
                continue;
            }
        }

        out.merged_text.push_str(line);
    }

    // Final flush.
    let here = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
    if here > buffered_start {
        push_span(out, buffered_start, here, source);
    }
}

/// Detect a line that opens or closes a fenced code block. Matches
/// `CommonMark`'s leading-whitespace tolerance (up to 3 spaces).
fn is_fence_line(line: &str) -> bool {
    let trimmed = line.trim_start_matches([' ', '\t']);
    trimmed.starts_with("```") || trimmed.starts_with("~~~")
}

/// Parse an `@import` line. Returns `Some(path)` if `line` is a
/// well-formed import directive, `None` otherwise.
///
/// Per the docs: imports are written as `@path/to/file`. We accept
/// either a bare line (`@path` only) or `@path` as the leading token
/// inside a list bullet, which the docs example shows
/// (`- @docs/git-instructions.md`). We require the `@` to begin a
/// word so prose like `email@example.com` doesn't match.
fn parse_import_line(line: &str) -> Option<String> {
    // Strip trailing newline and leading whitespace + bullet markers.
    let trimmed = line.trim_end_matches(['\r', '\n']);
    let body = trimmed.trim_start_matches([' ', '\t', '-', '*', '+']);
    let body = body.trim_start();

    // Must start with `@` and be the only token on the line (we don't
    // support inline `@import` references in prose — the docs show
    // only standalone-line and bullet usage).
    let after_at = body.strip_prefix('@')?;

    // The first whitespace ends the path; reject if there's trailing
    // non-whitespace content (e.g., `@path some other prose`).
    let mut parts = after_at.splitn(2, char::is_whitespace);
    let path = parts.next()?.to_string();
    if let Some(rest) = parts.next() {
        if !rest.trim().is_empty() {
            return None;
        }
    }

    if path.is_empty() {
        return None;
    }

    Some(path)
}

/// Resolve an import target relative to its source file's directory,
/// expanding `~/` to the home directory if present, then recurse.
fn resolve_import(
    target: &str,
    source: &Path,
    out: &mut MergedClaudeMd,
    visited: &mut HashSet<PathBuf>,
    depth: u8,
) {
    if depth >= MAX_IMPORT_DEPTH {
        emit_synthetic(
            out,
            source,
            &format!("<!-- solidterm: import depth exceeded for {target} -->\n"),
        );
        return;
    }

    let resolved = resolve_import_path(target, source);
    ingest_file(&resolved, out, visited, depth + 1);
}

/// Compute the absolute path for an `@import` target.
///
/// - `~/foo` → `<home>/foo` if `$HOME` is set.
/// - Absolute paths pass through.
/// - Relative paths join against the source file's parent directory.
fn resolve_import_path(target: &str, source: &Path) -> PathBuf {
    if let Some(rest) = target.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }

    let candidate = PathBuf::from(target);
    if candidate.is_absolute() {
        return candidate;
    }

    source
        .parent()
        .map_or_else(|| candidate.clone(), |parent| parent.join(target))
}

/// Append a synthetic line (warning / missing / cycle marker) and
/// attribute it to `attributed_to`.
fn emit_synthetic(out: &mut MergedClaudeMd, attributed_to: &Path, line: &str) {
    let start = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
    out.merged_text.push_str(line);
    let end = u32::try_from(out.merged_text.len()).unwrap_or(u32::MAX);
    push_span(out, start, end, attributed_to);
}

/// Push a `(start, end, source)` provenance span. Coalesces
/// consecutive spans that share a source path so the wire payload
/// stays compact.
fn push_span(out: &mut MergedClaudeMd, start: u32, end: u32, source: &Path) {
    if start >= end {
        return;
    }
    if let Some(last) = out.spans.last_mut() {
        if last.byte_end == start && last.source_path == source {
            last.byte_end = end;
            return;
        }
    }
    out.spans.push(ProvenanceSpan {
        byte_start: start,
        byte_end: end,
        source_path: source.to_path_buf(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    /// Helper: write `content` to `dir/relative` (creating parent
    /// directories as needed) and return the absolute path.
    fn write_file(dir: &Path, relative: &str, content: &str) -> PathBuf {
        let path = dir.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn no_imports_baseline_returns_concatenation() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, "CLAUDE.md", "project line\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("project line"));
        // One span for project content, plus possibly a trailing-newline
        // span if normalization fired (it didn't here — text already
        // ended with '\n').
        assert!(!merged.spans.is_empty());
        let project_path = cwd.join("CLAUDE.md").canonicalize().unwrap();
        let merged_canonical: Vec<PathBuf> = merged
            .spans
            .iter()
            .map(|s| {
                s.source_path
                    .canonicalize()
                    .unwrap_or_else(|_| s.source_path.clone())
            })
            .collect();
        assert!(merged_canonical.contains(&project_path));
    }

    #[test]
    fn cascade_orders_user_then_root_down() {
        let tmp = TempDir::new().unwrap();
        let home = tmp.path().join("home");
        let root = tmp.path().join("project");
        let nested = root.join("a").join("b");
        fs::create_dir_all(&nested).unwrap();
        fs::create_dir_all(home.join(".claude")).unwrap();

        write_file(&home, ".claude/CLAUDE.md", "USER_GLOBAL\n");
        write_file(&root, "CLAUDE.md", "PROJECT_ROOT\n");
        write_file(&nested, "CLAUDE.md", "NESTED_DIR\n");
        write_file(&nested, "CLAUDE.local.md", "NESTED_LOCAL\n");

        let merged = resolve(&nested, Some(&home));

        let user_idx = merged.merged_text.find("USER_GLOBAL").expect("user");
        let root_idx = merged.merged_text.find("PROJECT_ROOT").expect("root");
        let nested_idx = merged.merged_text.find("NESTED_DIR").expect("nested");
        let local_idx = merged.merged_text.find("NESTED_LOCAL").expect("local");

        assert!(user_idx < root_idx, "user-global before project-root");
        assert!(root_idx < nested_idx, "root before nested (root-down)");
        assert!(
            nested_idx < local_idx,
            "CLAUDE.md before CLAUDE.local.md at the same level"
        );
    }

    #[test]
    fn dot_claude_dir_picked_up_at_cwd() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, ".claude/CLAUDE.md", "DOT_CLAUDE\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("DOT_CLAUDE"));
    }

    #[test]
    fn imports_expand_inline_with_provenance_attribution() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        let imported = write_file(cwd, "imported.md", "FROM_IMPORT\n");
        write_file(cwd, "CLAUDE.md", "BEFORE\n@imported.md\nAFTER\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("BEFORE"));
        assert!(merged.merged_text.contains("FROM_IMPORT"));
        assert!(merged.merged_text.contains("AFTER"));

        // The import body must be attributed to `imported.md`, not to
        // the importer.
        let from_import_idx =
            u32::try_from(merged.merged_text.find("FROM_IMPORT").unwrap()).unwrap();
        let owning_span = merged
            .spans
            .iter()
            .find(|s| s.byte_start <= from_import_idx && from_import_idx < s.byte_end)
            .expect("span covers FROM_IMPORT");
        assert_eq!(
            owning_span.source_path.canonicalize().unwrap(),
            imported.canonicalize().unwrap()
        );
    }

    #[test]
    fn cycle_is_detected_and_skipped() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, "a.md", "A_TOP\n@b.md\nA_BOTTOM\n");
        write_file(cwd, "b.md", "B_TOP\n@a.md\nB_BOTTOM\n");
        write_file(cwd, "CLAUDE.md", "ROOT\n@a.md\nROOT_END\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("A_TOP"));
        assert!(merged.merged_text.contains("B_TOP"));
        // The cycle (b → a) must be skipped, but b's body before/after
        // the cycle-completing import still appears.
        assert!(merged.merged_text.contains("import cycle skipped"));
    }

    #[test]
    fn missing_import_emits_synthetic_warning() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, "CLAUDE.md", "PRE\n@nonexistent.md\nPOST\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("PRE"));
        assert!(merged.merged_text.contains("missing import"));
        assert!(merged.merged_text.contains("POST"));
    }

    #[test]
    fn deep_nesting_works_up_to_limit() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        // Chain: CLAUDE.md → 1 → 2 → 3 → 4 → 5 → 6 (6 should hit limit)
        for i in 1..=6 {
            let next = if i < 6 {
                format!("LEVEL_{i}\n@level{}.md\n", i + 1)
            } else {
                format!("LEVEL_{i}\n")
            };
            write_file(cwd, &format!("level{i}.md"), &next);
        }
        write_file(cwd, "CLAUDE.md", "ROOT\n@level1.md\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("LEVEL_1"));
        assert!(merged.merged_text.contains("LEVEL_4"));
        assert!(merged.merged_text.contains("LEVEL_5"));
        // Depth limit kicks in before LEVEL_6 (depth 5 import, target
        // would land at depth 6 which exceeds MAX_IMPORT_DEPTH = 5).
        assert!(
            !merged.merged_text.contains("LEVEL_6"),
            "depth limit must block 6th hop"
        );
        assert!(merged.merged_text.contains("import depth exceeded"));
    }

    #[test]
    fn at_inside_code_fence_is_not_an_import() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(
            cwd,
            "CLAUDE.md",
            "before\n```\n@should-not-resolve.md\n```\nafter\n",
        );

        let merged = resolve(cwd, None);

        // The literal `@should-not-resolve.md` line stays as text;
        // there must not be a missing-import synthetic for it.
        assert!(merged.merged_text.contains("@should-not-resolve.md"));
        assert!(
            !merged.merged_text.contains("missing import"),
            "code-fenced @path must not trigger import resolution"
        );
    }

    #[test]
    fn at_in_prose_email_is_not_an_import() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(
            cwd,
            "CLAUDE.md",
            "Contact me at user@example.com for questions.\n",
        );

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("user@example.com"));
        assert!(!merged.merged_text.contains("missing import"));
    }

    #[test]
    fn bullet_list_import_is_recognized() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, "extra.md", "EXTRA_BODY\n");
        write_file(cwd, "CLAUDE.md", "- @extra.md\n");

        let merged = resolve(cwd, None);

        assert!(merged.merged_text.contains("EXTRA_BODY"));
    }

    #[test]
    fn spans_cover_text_contiguously_without_gaps() {
        let tmp = TempDir::new().unwrap();
        let cwd = tmp.path();
        write_file(cwd, "imp.md", "IMP\n");
        write_file(cwd, "CLAUDE.md", "A\n@imp.md\nB\n");

        let merged = resolve(cwd, None);

        // Spans must be sorted and cover [0, len) with no gaps.
        let mut cursor: u32 = 0;
        for span in &merged.spans {
            assert_eq!(span.byte_start, cursor, "no gap between spans");
            assert!(span.byte_end > span.byte_start, "non-empty span");
            cursor = span.byte_end;
        }
        assert_eq!(cursor as usize, merged.merged_text.len());
    }

    #[test]
    fn empty_cascade_yields_empty_merge() {
        let tmp = TempDir::new().unwrap();
        let merged = resolve(tmp.path(), None);
        assert!(merged.merged_text.is_empty());
        assert!(merged.spans.is_empty());
    }
}
