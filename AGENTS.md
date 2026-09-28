# Agent guidelines

Feedback collected during work on `agent-vm/`. Applies repo-wide.

## Writing

- Minimum words. Pick each one deliberately. Comments, commit messages, replies - all of it.
- No superlatives, no praise, no "you're right". State facts.
- Blank line between logical blocks of code. Let it breathe.
- Comments say what a block does and why, briefly. Example or ASCII diagram if a system needs it.

## Working

- Don't test right after a requested revert. Wait for a go-ahead - rebuilds are expensive, don't assume.
- Verify claims about library internals by reading the source or testing empirically, not from memory. Say so when you did.
- Before writing off an approach as impossible, check one level deeper. "Not exposed at this layer" isn't "not possible" - a nixpkgs override can hide the exact seam you need one function-call down (`pkgs.buildLinux` vs `pkgs.linuxManualConfig`).
- Prefer stable/public APIs over reaching into internal file paths (`pkgs.linuxManualConfig`, not `pkgs.path + "/pkgs/os-specific/..."`), even when the internal path also works.
- If a fix works but is more convoluted than it needs to be, say so and simplify - don't defend the first working version.

## Vault scope

This repository is an Obsidian vault, root at repo top. Every `.md` file, anywhere in the tree, follows the same rules as the obsidian-mcp interface - not just files under `docs/`.

- The obsidian-mcp server is always available and required. Always use `mcp__obsidian__*` tools, never plain file I/O, when working with a note - a text file holding prose, not code.
- `.claude/**` and `AGENTS.md` are excluded from search at the server level (`OBSIDIAN_EXCLUDE_PATHS`). They still appear in `vault_list` and are readable via `note_read` - the exclusion only removes them from search/semantic/wikilinks results. That mismatch (visible in listings, absent from search) is deliberate. Don't try to reconcile it.
- Internal references are wikilinks (`[[note]]` or `[[note#heading]]`), not relative markdown paths.
- Frontmatter is set via `frontmatter`, not hand-edited YAML.
- Moves/renames go through `note_move` so links stay intact.

## Vault interaction discipline

Use each tool for what it's built for - search is separate from full-content retrieval, and incremental edit is separate from full rewrite.

- **Search before reading.** `search_text`/`search_semantic` return snippets for discovery. Pull full content with `note_read`/`note_read_many` only for a note you're about to cite or edit.
- **Batch reads.** Use `note_read_many` for multiple notes, not a loop of `note_read` calls. Scope `vault_list` to a directory or glob, not the whole vault.
- **Create early, grow incrementally.** `note_create` once a note's shape is stable, then extend it with `note_patch` - not `note_write` again. `note_patch` is the incremental-edit tool; `note_write` replaces the whole note.
- **Don't read back to verify.** Trust a `note_patch`/`note_create` result the way you'd trust a local file edit - the tool's response already confirms the change.
- **Link late.** Query `wikilinks` only when actually adding a link, to confirm the target exists.
- **Hand off, don't paste.** Use `open_in_obsidian` so the user opens the real note in the app, instead of re-emitting note content into the conversation.

## Repo structure docs

- Keep repo structure information in sync as the tree changes - stale layout docs are worse than none.
- A `README.md`, where one exists, is the authoritative structure doc for its own directory level and subfolders. Update it, not some other note, when that subtree's layout changes. See `agent-vm/README.md`'s "Source layout" section for the expected shape.
