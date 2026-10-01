# Agent guidelines

Applies repo-wide.

## Writing

- Minimum words. Pick each one deliberately. Comments, commit messages, replies - all of it.
- No superlatives, no praise, no "you're right". State facts.
- Blank line between logical blocks of code. Let it breathe.
- Comments say what a block does and why, briefly. Example or ASCII diagram if a system needs it.

## Working

- Don't test right after a requested revert. Wait for a go-ahead - rebuilds are expensive, don't assume.
- Verify claims about library internals by reading the source or testing empirically, not from memory. Say so when you did.
- Before writing off an approach as impossible, check one level deeper. "Not exposed at this layer" isn't "not possible" - a nixpkgs override can hide the seam one call down (`pkgs.buildLinux` vs `pkgs.linuxManualConfig`).
- Prefer stable/public APIs over internal file paths (`pkgs.linuxManualConfig`, not `pkgs.path + "/pkgs/os-specific/..."`).
- If a fix works but is more convoluted than it needs to be, say so and simplify - don't defend the first working version.

## Git

- Commit as `Bert&Bot <bert+bot@proesmans.eu>`. Pass via `git -c user.name=... -c user.email=...`; don't change git config.
- Subject: short, imperative, no trailing period ("Add root README.md documenting the repo-root nix files").

## Vault scope

This repository is an Obsidian vault, root at repo top. Every `.md` file, anywhere in the tree, follows the same rules as the obsidian-mcp interface.

- The obsidian-mcp server is always available and required. Always use `mcp__obsidian__*` tools, never plain file I/O, when working with a note - a text file holding prose, not code.
- `AGENTS.md` and `archive/**` are excluded from search (`OBSIDIAN_EXCLUDE_PATHS` in `.mcp.json`). They still appear in `vault_list` and are readable via `note_read`. Intentional; don't reconcile.
- Internal references are wikilinks (`[[note]]` or `[[note#heading]]`), not relative markdown paths.
- Frontmatter is set via `frontmatter`, not hand-edited YAML.
- Moves/renames go through `note_move` so links stay intact.
- A `README.md` is the authoritative structure doc for its directory and subfolders. Update it when that layout changes.

## Vault interaction discipline

- **Search before reading.** `search_text`/`search_semantic` for discovery; `note_read`/`note_read_many` only for a note you're about to cite or edit.
- **Batch reads.** `note_read_many`, not a loop of `note_read`. Scope `vault_list` to a directory or glob.
- **Create early, grow incrementally.** `note_create` once the shape is stable, then `note_patch`. `note_write` replaces the whole note.
- **Don't read back to verify.** The `note_patch`/`note_create` response confirms the change.
- **Link late.** Query `wikilinks` only when adding a link.
- **Hand off, don't paste.** `open_in_obsidian` instead of re-emitting note content.
