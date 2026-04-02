---
name: build-things
description: Turn short product or engineering requests into working code changes with validation. Use when the user asks to build a feature, implement an idea, scaffold a component, wire integrations, or ship an end-to-end change in an existing codebase.
---

# Build Things

Execute end-to-end implementation work with clear assumptions, minimal churn, and verification.

## Workflow

1. Confirm goal and constraints.
- Restate the requested outcome in one sentence.
- Infer missing details only when needed to keep momentum.
- Prefer progress over broad clarification loops.

2. Map the implementation surface.
- Locate relevant files and existing patterns with fast search.
- Reuse current architecture and naming conventions.
- Avoid touching unrelated areas.

3. Plan the smallest viable diff.
- Define the minimal set of files and changes required.
- Sequence changes to keep the app/build in a runnable state.
- Flag risky assumptions before coding.

4. Implement directly.
- Apply focused edits; keep logic readable and deterministic.
- Add concise comments only where intent is non-obvious.
- Preserve backward compatibility unless the request says otherwise.

5. Verify behavior.
- Run the narrowest meaningful checks first, then broader tests as needed.
- Prefer existing test harnesses over ad hoc scripts.
- If validation cannot run, report exactly what is unverified.

6. Deliver results.
- Summarize what changed and why.
- Include file paths and key behavior impacts.
- Provide next steps only when they are actionable.

## Quality Bar

- Prefer concrete completion over partial scaffolding.
- Keep diffs minimal, reversible, and easy to review.
- Maintain consistency with repository standards and tooling.
