---
description: Derive a checklist todo note from a finalized implementation plan note, and roll its chunk-level progress into a repo-root TODO.md. Use once a plan note is finalized, or whenever a todo note's checkboxes change and the root rollup needs updating.
name: plan-to-todo
---
# Plan To Todo

## Scope and mapping

- Input: one finalized plan note (every step has a prompt, sizing review is done).
- Output: one todo note, sibling to the plan note, `<spec-name>-todo.md` naming, unless the area already has a convention.
- Output (maintained, not recreated per run): one repo-root `TODO.md` aggregating every per-spec todo note's chunk-level progress — a single file shared across all specs, not one per spec.
- Run this whenever a plan note is finalized (first todo generation), and again whenever a todo note's checkboxes change or its plan is revised (rollup maintenance).

## Procedure

1. **Todo.** Derive the todo note from the plan note — see Todo note shape below.
2. **Root rollup.** Patch this spec's section into the repo-root todo note in the same pass — see Root todo note below. Never leave this for later.

## Todo note shape

Purpose: a working checklist for executing the plan, not a second copy of it. Thorough means every step and every one of its done-conditions is a checkable line — not prose summarizing the plan.

- Mirror the plan's structure: a heading per chunk, in build order, matching the plan's chunk list.
- Under each chunk heading, one top-level checklist item per step, in build order:
  `- [ ] Step N — <short imperative title>` wikilinked to that step's section in the plan note (`[[<plan-note>#Step N — ...]]`), so ticking the box never loses traceability to the full prompt.
- Under each step, nested checklist items for its concrete done-conditions, extracted from that step's own prompt — not invented separately:
  - the implementation the prompt asked for
  - the wiring into the previous step's output that the prompt's closing instruction specified
  - whatever the prompt named as the way to verify the step (a test, a build, a manual run) — write it as the actual command or check, not "verify it works"
- A step's top-level box is a summary checkbox; check it only when every nested box under it is checked. Say so once at the top of the note so it's not ambiguous per-step.
- No narrative between checklist items. If a step needs a caveat, put it as a nested bullet under that step, not a paragraph between sections.

If the plan note is later edited (steps added, reordered, split), regenerate the affected part of the todo note by patching — preserve already-checked boxes for steps that didn't change rather than recreating the note wholesale.

## Root todo note (repo-wide rollup)

One file, `TODO.md` at repo root, aggregating every per-spec todo note at chunk granularity — a glanceable high-level progress report, not a full checklist.

- One section per spec that has a todo note, heading wikilinked to that todo note: `## [[<spec-name>-todo]]`, in dependency order (match the order the specs were processed in).
- Under each spec's heading, one checklist item per chunk — its first-level sections, in the todo note's own order:
  `- [ ] <chunk heading>` wikilinked to that chunk's section in the todo note (`[[<spec-name>-todo#<chunk heading>]]`).
- A chunk's box here is checked only when every step under that chunk in the todo note is fully checked (all its nested done-conditions too). This file never tracks step- or done-condition-level detail directly — that granularity stays in the per-spec todo note; drill in via the link.
- Maintain in-line: this file is a living document, not a one-time export. Whenever a per-spec todo note's chunk-level completion changes for any reason (steps checked off, plan revised), patch this file's corresponding line in the same pass — never regenerate the whole file, never let it fall out of sync.
- When a new spec's plan+todo is created, patch-insert its section in dependency order (resequence neighbors if needed), don't append blindly at the end.

## Grounding

Read the plan note in full before deriving or updating its todo note — done-conditions come from what the plan's prompts actually say, not from re-deriving them from the underlying spec.
