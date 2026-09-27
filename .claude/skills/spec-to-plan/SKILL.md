---
name: spec-to-plan
description: Convert a finalized specification note into a step-by-step, codegen-ready implementation plan note. Use when spec documents in the vault are stable and the user wants a build plan, one plan note per spec note. Hands off to the plan-to-todo skill for the checklist and progress rollup.
---

# Spec To Plan

## Scope and mapping

- Input: one spec note, or a linked set (e.g. `docs/agent-vm-host/00-index.md` and its numbered children).
- Output per spec note: one plan note. Sibling location, `<spec-name>-plan.md` naming, unless the vault area already has a convention (check before inventing one).
- A plan may reference another spec's or plan's content for context or dependency — wikilink it, don't duplicate it.
- Skip notes that aren't independently buildable (indexes, decision logs) unless the user asks for one explicitly.
- Process specs in dependency order — check the index / decisions log for what depends on what before starting the first plan, so later plans link back to settled sequencing instead of re-deriving it.

## Procedure
## Procedure

Run per spec note:

1. **Blueprint.** Draft the end-to-end build blueprint: what gets built, in what order, dependencies, the finished state.
2. **First split.** Break the blueprint into large chunks, each a coherent piece of working functionality that builds on the previous chunk.
3. **Second split.** Break each chunk into small steps.
4. **Right-size.** Review every step: small enough to implement and verify safely in isolation, big enough to move the project forward — no step that only sets up for a later step without producing something working itself. Merge undersized steps, split oversized ones. Repeat until sizing holds.
5. **Prompts.** Convert each final step into a self-contained code-generation prompt. State the context a fresh codegen LLM needs (what prior steps already produced, what this step must produce), the concrete task, and close by wiring the new code into what came before. No orphaned code — everything produced must be called from somewhere by the end of its own step.
6. **Suggest todo.** Once the plan note is finalized (every step has a prompt, sizing review is done), tell the user the plan is ready and suggest running the `plan-to-todo` skill next. Don't invoke it automatically — running it is the user's call, made when they choose to spend the context on it.

Consecutive prompts build strictly on prior ones. A prompt must never assume a step the reader hasn't seen yet.
## Plan note shape

- Body, in order: blueprint summary, chunk list, then one section per step prompt.
- Each prompt's actual text goes in a fenced ` ```text ` block — copy-pasteable whole into a codegen session. Framing (which step, what it depends on) is prose immediately above the block, never inside it.

## Grounding

Read the spec note in full, plus anything it wikilinks that step sequencing depends on, before drafting the blueprint. Don't infer implementation details the spec doesn't state — flag the gap back to the user instead of guessing.
