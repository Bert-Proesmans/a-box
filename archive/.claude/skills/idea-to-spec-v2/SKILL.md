---
description: Turn a rough idea into a developer-ready specification through an iterative, one-question-at-a-time interview. Use when a stakeholder describes a project at a high level and wants a thorough, detailed spec built up collaboratively rather than guessed at in one pass. The spec is a linked set of notes - an index, a decisions log and one note per independently buildable component.
name: idea-to-spec
---

# Idea To Spec

This is the approach used to turn "a virtual machine host that holds
ram-resident kvm guests running an llm code agent..." into a full,
implementation-ready specification. It generalizes to any "help me spec this
out" request. Examples throughout come from that project and are illustrative
only; the tools and technologies they name are not requirements.

"The spec" below means the whole linked set of notes: an index, a decisions
log and one note per independently buildable component (see "Layout").

## Core loop

1. **One question at a time.** Ask exactly one decision per ask; never bundle
   decisions, related or not. Prefer the question that follows from the
   previous answer — scale decided threat model, threat model decided proxy
   strictness, proxy strictness decided TLS handling, and so on. If a
   question would make equal sense at the very start of the interview, it's
   probably not built on enough context yet. The opening question has no
   previous answer: start with the first area in "Coverage and stopping".
2. **Structured choices, not open questions.** Ask with the `ask` tool (if it
   is unavailable, a numbered list in chat with the same structure): 2–4
   mutually exclusive options, a clearly marked recommended default, and
   honest one-line tradeoffs for each — including the recommended one. This
   does two things: it lets the stakeholder answer in five seconds when they
   don't have a strong opinion, and it forces you to have already thought
   through the tradeoff before asking, rather than outsourcing that thinking
   to them. Exception: clarifying and fact-gathering questions (the opening
   "what is this for?", "what do you mean by X?") may be open; switch to
   structured choices as soon as there are options to weigh.
3. **Compile as you go, not at the end.** Don't wait until every question is
   answered to start writing. Once a cluster of related decisions is stable
   — no pending follow-up question can still change it (e.g. "isolation
   mechanism" settled across networking + interactive channel + storage) —
   write it into the matching notes (see "Timing"). Don't write earlier.
4. **Stop on coverage, not on fatigue.** The stop rule is in "Coverage and
   stopping" below.

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
  the question at hand: update that decision's log entry, every dependent
  decision, and every note that links to it. Re-ask the stakeholder only
  where the change invalidates an option they previously chose; never flip
  their earlier choices silently. When git access scope flipped from "no git
  at all" to "read-only protocol access to a master server," it changed the
  workspace-delivery design, the proxy allowlist, and the block-device
  layout — all of which had to be revisited together, not left
  inconsistent.
- **Let a clarifying question replace a bad question.** If a question you
  asked gets rejected as unclear or premature, don't just answer it
  yourself — ask what needs clarifying, then re-ask a sharper version once
  you understand the gap. If the stakeholder both rejects the question and
  questions the direction, handle the direction first.

## Grounding decisions in fact, not memory

When a design choice hinges on a specific technical claim (a tool's
capabilities, a library's constraints, a platform's device model), **verify
it before asking the question that depends on it**, don't answer from
possibly-stale recall. Before asking how the host↔guest interactive channel
should work, Firecracker's actual supported device list was looked up and
cited — that fact (no virtio-console, single UART, multi-port vsock) is what
made the recommended answer correct rather than a guess. Cite sources in the
question's option text and in the matching decisions log entry.

## Calibrating depth to stated scale

Early answers about scale and threat model should visibly cap how much
machinery gets proposed later. "Single developer, personal use" is why
seccomp, ZFS dedup, and per-task resource overrides were all explicitly
rejected in favor of simpler defaults — not because they're bad ideas in
general, but because the complexity they add wasn't worth it at the stated
scale. When recommending an option, say why it fits *this* stakeholder's
scale, not just why it's a good practice in the abstract.

## Coverage and stopping

The interview ends when each area below is decided, explicitly marked out of
scope, or recorded in `Open gaps` — not when the stakeholder runs out of
answers. Track coverage as you go. The list is in dependency order: prefer
the question that follows from the last answer (Core loop, item 1); when
nothing follows, take the first uncovered area in list order.

- Purpose and users
- Scale and threat model
- Components and interfaces
- Data and state
- Failure modes and recovery
- Operations (deploy, upgrade, observe)
- Acceptance criteria (how to verify it works)
- Non-goals

An area that doesn't apply is marked out of scope in the index coverage
checklist, with the reason in the decisions log's non-goals — not silently
omitted. The Non-goals area is covered once the log's non-goals section lists
what was ruled out, or states there is nothing.

Where each area's content lives:

- Index (cross-cutting): purpose and users, scale and threat model,
  operations, the component list and build order, and system-level
  acceptance criteria.
- Child note (per component): interfaces, data and state, failure modes and
  recovery, acceptance criteria, and component-specific deploy/observe
  details.
- Decisions log: non-goals.

## Decisions log and non-goals

Record every settled decision — cross-cutting or component-local — in the
decisions log note (see "Layout"): the decision, why, and the options
rejected. Child notes hold the resulting specification (what is built) and
link to the log entry for the why; they never restate the rationale.

Non-goals are a section of the log. They list areas ruled out of scope and
options that are sound in general but rejected for this stakeholder's scale
(e.g. seccomp, ZFS dedup), each with its reason, so later readers don't
reopen them. Options rejected within an ordinary decision stay in that
decision's entry.

When a decision changes, follow the propagation rule in "Handling pushback
and correction".

## Open gaps

A gap is a question or area the stakeholder defers or cannot answer. When the
stakeholder is stuck, offer "defer to Open gaps" as an option. Record each gap
when it is deferred, in an `Open gaps` section of the index: the question, why
it matters, and what depends on it. Anything still unresolved when the
interview ends is recorded the same way. An area recorded as a gap counts as
covered for the stop rule. Never fill a gap with a guess. A reader of the spec
must be able to tell settled from unsettled.

## Producing the deliverable

The deliverable is a linked set of notes, not a chat reply, stored where the
project keeps its documentation. The three-part structure below is
mandatory; file names, link syntax and location follow the project's own
conventions (check agent guidelines such as `AGENTS.md` if present) rather
than inventing a format.

### Layout

Always split, regardless of size:

- **Index note** (e.g. `00-index.md`): overview, the cross-cutting areas
  (see "Coverage and stopping"), the build/dependency order between
  children, the coverage checklist, links to every child, and the
  `Open gaps` section.
- **Decisions log note** (e.g. `decisions.md`): every settled decision and
  the non-goals section, cross-cutting or component-local. Every child
  depends on it, so it stands alone rather than living inside one child.
- **One child note per independently buildable component** (e.g. numbered
  `01-…`, `02-…`) holding that component's per-component areas (see
  "Coverage and stopping"). A component is independently buildable if it can
  be built and verified on its own; one that can't is merged into the child
  of the component it depends on. A one-component project still gets an
  index, a decisions log and one child, so downstream readers always see the
  same shape.

Why: a monolithic note must be re-read whole to resume the interview, to
reconcile a changed decision, and by every downstream reader. Split notes let
each of those load the index, the decisions log and one child. The cost is
cross-file consistency, so follow the propagation rule in "Handling pushback
and correction" whenever a decision changes.

### Timing

Create the index and decisions log as soon as the first cluster of decisions
is stable (Core loop, item 3) — don't hold the draft in conversation until
the interview finishes. Add each child as its cluster of decisions settles.
On every write, keep the decisions log, the index's child links, build order
and coverage checklist, and `Open gaps` in step with the notes.
