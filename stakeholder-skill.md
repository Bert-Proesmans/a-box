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

- Match the deliverable's form to its actual audience. A spec meant for
  "hand this to a developer" gets written as a real document (headed
  sections, tables, rationale — not a chat transcript) and delivered in
  whatever form that audience will actually use: here, both a versioned
  Markdown file committed to the repo (source of truth, diffable,
  co-located with the code it describes) and a polished, navigable page for
  easy review/sharing.
- Keep both in sync. When a later question deep-dives into a mechanism the
  spec only gestured at (e.g. "how does the guest resolve DNS?"), work out
  the concrete answer first, then fold it back into *every* copy of the
  spec — don't let the conversation's understanding outrun the document.
- End a deep-dive by offering to fold it in, rather than assuming silence
  means "leave the docs stale."
