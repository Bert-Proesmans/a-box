---
name: stakeholder-interview
description: Turn a rough idea into a developer-ready specification through an iterative, one-question-at-a-time interview. Use when a stakeholder describes a project at a high level and wants a thorough, detailed spec built up collaboratively rather than guessed at in one pass.
---

# Stakeholder Interview

This is the approach used to turn "a virtual machine host that holds
ram-resident kvm guests running an llm code agent..." into a full,
implementation-ready specification (see `docs/agent-vm-host-spec.md` in this
repo for the result). It generalizes to any "help me spec this out" request.

## Core loop

1. **One question at a time.** Never batch unrelated decisions into one ask.
   Each question should only make sense *because* of the answer to the
   previous one — scale decided threat model, threat model decided proxy
   strictness, proxy strictness decided TLS handling, and so on. If a
   question would make equal sense at the very start of the interview, it's
   probably not built on enough context yet.
2. **Structured choices, not open questions.** Use a multiple-choice format
   (2–4 mutually exclusive options) with a clearly marked recommended
   default and honest one-line tradeoffs for each — including the
   recommended one. This does two things: it lets the stakeholder answer in
   five seconds when they don't have a strong opinion, and it forces you to
   have already thought through the tradeoff before asking, rather than
   outsourcing that thinking to them.
3. **Compile as you go, not at the end.** Don't wait until every question is
   answered to start writing. Once a cluster of related decisions is stable
   (e.g. "isolation mechanism" settled across networking + interactive
   channel + storage), it's fine to write that section — but don't write
   prematurely, before related follow-up questions might still change it.

## Handling pushback and correction

- **When the stakeholder questions a direction ("are we just reinventing
  X?", "is this overkill?"), stop and analyze — don't just rephrase the same
  question.** Compare the proposed approach against the thing they named
  (what problem does X actually solve, does that problem exist here) and
  give a real recommendation before asking anything further. See how "are we
  practically replicating nsjail?" produced a full compare-and-recommend
  answer before the next question, not a deflection back to them.
- **When they change their mind mid-interview, thread it through
  everything already decided that depended on the old answer**, not just
  the question at hand. When git access scope flipped from "no git at all"
  to "read-only protocol access to a master server," it changed the
  workspace-delivery design, the proxy allowlist, and the block-device
  layout — all of which had to be revisited together, not left
  inconsistent.
- **Let a clarifying question replace a bad question.** If a question you
  asked gets rejected as unclear or premature, don't just answer it
  yourself — ask what needs clarifying, then re-ask a sharper version once
  you understand the gap.

## Grounding decisions in fact, not memory

When a design choice hinges on a specific technical claim (a tool's
capabilities, a library's constraints, a platform's device model), **verify
it before asking the question that depends on it**, don't answer from
possibly-stale recall. Before asking how the host↔guest interactive channel
should work, Firecracker's actual supported device list was looked up and
cited — that fact (no virtio-console, single UART, multi-port vsock) is what
made the recommended answer correct rather than a guess. Cite sources when
you do this.

Also ground the spec in the actual project, not just the stakeholder's
description of it: read existing repository files (`llm-host.nix` here)
before finalizing, so the spec reconciles with what's already true on disk
instead of describing a parallel-universe version of the project.

## Calibrating depth to stated scale

Early answers about scale and threat model should visibly cap how much
machinery gets proposed later. "Single developer, personal use" is why
seccomp, ZFS dedup, and per-task resource overrides were all explicitly
rejected in favor of simpler defaults — not because they're bad ideas in
general, but because the complexity they add wasn't worth it at the stated
scale. When recommending an option, say why it fits *this* stakeholder's
scale, not just why it's a good practice in the abstract.

## Producing the deliverable

The deliverable is a single note in the Obsidian vault — not a repo file,
not a chat reply. Every step below is chosen for token cost, not just
correctness: the MCP round-trip and the payload size both count.

1. **Before drafting, search — don't read.** `search_text`/`search_semantic`
   return snippets, not full notes; use them to check whether a prior spec
   already covers this. Pull full content only for a note you're about to
   cite or extend, and batch it — `note_read_many`, never one `note_read`
   per file. Scope `vault_list` to a directory or glob, not the whole
   vault.
2. **Start the note early.** Once the first cluster of decisions is
   stable, `note_create` it — don't hold the draft in conversation until
   the interview finishes.
3. **Grow it section by section with `note_patch`, never `note_write`
   again.** `note_write` re-sends the entire note on every edit, so its
   cost grows with the note; `note_patch` costs only the size of the
   change. Over a long interview that's the difference that matters.
4. **Don't read back to verify.** Trust a `note_patch` result like you'd
   trust a local file edit — a confirming `note_read` re-spends the whole
   note in tokens for nothing new.
5. **Link late, not speculatively.** Query `wikilinks` only at the point
   you're adding a link, to confirm the target exists — not up front
   against the whole graph.
6. **Hand off with `open_in_obsidian`, not a paste.** The stakeholder opens
   it in the app; don't re-emit the note's content into the conversation
   just to show it.
