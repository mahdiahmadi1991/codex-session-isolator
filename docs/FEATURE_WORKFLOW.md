# Feature Development Workflow

This workflow is the repository standard for new feature development.

It applies when the user asks for a feature to be designed or developed. It does not automatically apply to bug fixes unless the user explicitly asks for the same level of gated execution.

## Goals

- make feature work auditable before code changes begin
- keep implementation aligned with an explicit idea document
- let the user review scope and behavior in small, logical checkpoints
- make handoff predictable for other models and contributors
- keep the assistant in an active advisory role, not a passive executor
- surface breakage risk, context drift, and weak assumptions before implementation

## Mandatory Lifecycle

### 0. Act as an advisor during idea formation

When discussing a feature idea, the assistant must act as an advisor.

That means:

- challenge ideas that may introduce breakage, unsafe migration paths, or trust regressions
- point out when the user may be operating with stale or incomplete context
- propose stronger alternatives, safer scope boundaries, or better UX where appropriate
- improve the idea before implementation starts instead of merely restating it

The assistant should help mature the feature idea, not just record it.

### 1. Create an idea document first

Before implementation starts, create or update a feature idea file under `ideas/`.

Recommended naming:

- `ideas/<feature-name>.md`

The idea file is the source of truth for the planned work until the feature is completed or deliberately re-scoped.

### 2. Document the feature in enough detail for handoff

The idea file must be detailed enough that another model or engineer can continue the work with minimal ambiguity.

At minimum, record:

- feature goal
- user-visible behavior
- scope
- non-goals
- assumptions
- risks and safety boundaries
- affected files or subsystems
- validation strategy
- execution plan broken into logical, topic-based steps
- approval gates between steps
- open questions and resolved answers when ambiguity existed

Do not keep the idea file as a vague note. It must be operational.

### 2.5 Resolve ambiguity before proposing implementation

Do not guess through idea ambiguity during implementation.

If the feature idea has gaps that could affect behavior, compatibility, safety, migration, or UX:

- stop during idea formation
- ask targeted clarification questions
- wait for answers
- then update the idea document and execution plan

Only proceed to implementation planning after the important ambiguities are resolved.

Reason:

- guessing at execution time creates avoidable breakage
- hidden assumptions make review weaker
- explicit clarification produces better plans and safer delivery

### 3. Break the work into explicit steps

Each feature must be broken into logical steps that are small enough to review, but large enough to deliver coherent value.

Each step should include:

- purpose
- planned changes
- expected outputs
- validation or verification criteria
- follow-up dependencies, if any

Prefer grouping by topic or system boundary, not by arbitrary file count.

### 4. Get approval before implementation starts

After the idea document is ready, summarize the planned steps for the user in concise form and ask for approval before starting implementation.

Do not start coding the feature before the user approves the step plan.

### 5. Execute one step at a time

After approval, implement only the next approved step.

For each step:

1. restate the step being executed
2. implement it
3. run the validations relevant to that step
4. summarize what changed
5. stop and wait for user review/approval before continuing

Do not silently continue into the next step.

### 6. Update the idea document if scope changes

If implementation uncovers scope changes, design changes, or new risks:

- update the idea file first
- clearly mark what changed
- summarize the delta for the user
- get approval again before continuing

### 7. Include a dedicated alignment-review step

Every feature plan must include a step whose purpose is to compare the implemented work against the original idea and find mismatches.

That step should:

- compare delivered behavior vs planned behavior
- identify missing pieces
- identify unintended deviations
- either propose follow-up fixes or confirm alignment

### 8. Include a user-testing handoff step

Every feature plan must include a step that prepares user testing.

That step should:

- summarize what is ready to test
- list test conditions or environments
- list important edge cases
- identify known limitations
- wait for user confirmation before moving into final wrap-up

### 9. Finish with commit-readiness, not silent closure

The final step must confirm:

- implemented scope
- validation status
- known gaps, if any
- workspace status
- readiness to commit on the feature branch

If the user wants a commit, do it only after this readiness checkpoint.

## Idea File Template

Each idea file should be organized in a structure close to this:

1. Feature Summary
2. Goal
3. User-Facing Behavior
4. Scope
5. Non-Goals
6. Safety / Trust Boundaries
7. Risks / Edge Cases
8. Open Questions / Resolutions
9. Affected Areas
10. Validation Strategy
11. Execution Steps
12. Current Status

For `Execution Steps`, use a repeatable structure:

- `Step N: <name>`
- purpose
- planned work
- validation
- approval gate

## Step Status Conventions

Use clear state labels inside the idea file when useful:

- `Pending`
- `Ready for approval`
- `Approved`
- `In progress`
- `Completed`
- `Blocked`

The current step should be obvious to a future reader.

## Suggested Collaboration Pattern

When presenting the step plan to the user:

- keep the summary concise
- keep the document detailed
- call out important risks, breaking-change concerns, and unresolved decisions
- ask for approval of the next step only

When a step is complete:

- summarize the result
- point to the updated files
- mention validations run or not run
- wait for review

## Exceptions

If the user explicitly asks to skip this process for a feature, follow the user's instruction.

If the work is actually a bug fix rather than a feature, this workflow is optional unless the user requests it.
