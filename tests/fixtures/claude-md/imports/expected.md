# Imports test — primary file

Some local content here.

# Conventions (imported)

- Tabs for Go, spaces for everything else.
- Commit messages use Conventional Commits.

[!] @./missing-file.md — file not found, skipped (logged)

# Circular A

Imports B, which imports A — must break cycle.

# Circular B

[!] @circular-a.md — circular import, skipped (logged)

Cycle should be detected; loader logs a warning and skips re-import.

End of primary.
