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
