# Marketplace Polish And Trust Presentation

## Feature Summary

Improve the public-facing presentation of the VS Code extension and repository so the product looks more mature, communicates trust more clearly, and reduces ambiguity about support and validation.

This work focuses on Marketplace-facing surfaces and the repository README, not on launcher/runtime behavior.

## Goal

Make the product look more professional and more trustworthy without overstating compatibility.

Success means:

- the Marketplace-facing README is easier to scan
- trust and validation signals are visible near the top of the page
- badge usage is intentional rather than noisy
- support boundaries are clearer
- screenshots and visual assets better reflect the current extension surface

## Advisory Notes

- Too many badges make an extension look cluttered and low-signal. A smaller, curated set is stronger than a long badge wall.
- We should not claim platform support beyond what is actually validated.
- Marketplace polish should improve conversion and trust without turning the README into marketing fluff.
- If we add screenshots, they should match the current command surface exactly and avoid stale UI details.

## Current Findings

- The root README already has CI, Security, Release, License, and VS Code badges.
- The extension README now has CI, Security, and VS Code badges, but it can still be structured more intentionally.
- Validation/scope disclaimers now exist, but they can be presented more clearly in the Marketplace-facing flow.
- The current visual assets are limited to `hero.png`, `icon.png`, and the repo banner SVG.
- The extension README is informative, but the top section is still more descriptive than conversion-oriented.

## Scope

- improve Marketplace-facing README structure and polish
- refine badge selection and ordering
- add a concise trust/validation block near the top
- improve visual presentation recommendations and, if approved, add/update supporting assets
- keep docs aligned with actual tested-platform claims

## Non-Goals

- changing launcher behavior
- changing release automation
- adding telemetry, analytics, or outbound services
- inventing support claims that are not backed by the current validation matrix

## Proposed Direction

### Badge strategy

Prefer a compact top row in the Marketplace-facing README:

- `CI`
- `Security`
- `VS Code 1.95+`

Do not include `Release` in the Marketplace-facing badge row. It is more useful in the repository README than on the extension page.

Keep `License` in the root README, but not necessarily in the extension README if the badge row starts feeling crowded.

Optional second row only if signal is strong enough:

- `No Telemetry`
- `Tested: Windows | Linux | macOS | WSL manual`

Avoid adding weak vanity badges unless they communicate real user value.

Badges we should explicitly avoid for now:

- star count
- issue count
- installs/rating badges unless their data source is stable and renders cleanly
- any badge that implies platform support beyond the current validation matrix

### README presentation

Rework the top of the Marketplace README into this order:

1. title + hero
2. compact badge row
3. one-paragraph value proposition
4. short `Why trust this extension` block
5. short `Tested environments` block
6. short `What you can do` / command summary
7. quick start

### Visual polish

Potential improvements:

- add one screenshot of the three primary commands in Command Palette
- add one screenshot of the setup flow or rollback flow only if the UI is stable enough
- keep the hero, but ensure surrounding text does not duplicate what the hero already says

### Trust presentation

Explicitly surface:

- local-first behavior
- no telemetry
- project-scoped changes only
- validated environments vs best-effort environments

## Risks / Edge Cases

- badge clutter can reduce clarity if we overdo it
- screenshots can become stale when command names or UI flows change
- a stronger trust section must stay consistent with `docs/TRUST.md`
- Marketplace README and root README should not drift into conflicting promises

## Affected Areas

- `extension/README.md`
- `README.md`
- `docs/TRUST.md`
- `docs/TESTING.md`
- `docs/MARKETPLACE.md`
- `extension/media/` if new visual assets are added

## Validation Strategy

- direct review of badge rendering and README structure
- extension package validation to ensure README/assets still package correctly
- consistency review against trust/testing docs

## Execution Steps

### Step 1: Finalize presentation strategy and badge set

Status:

- `Completed`

Purpose:

- settle the exact top-of-page trust and polish direction before editing assets/docs

Implementation notes:

- `Root README`: keep `CI`, `Security`, `Release`, `VS Code 1.95+`, and `License`.
- `Marketplace-facing extension README`: keep a tighter badge set focused on trust and compatibility rather than repo metadata noise.
- `Marketplace-facing final badge target`: `CI`, `Security`, `VS Code 1.95+`, plus at most one additional trust-oriented badge if it remains visually clean.
- `No Telemetry` and `Tested environments` are approved as candidate badges, but only if they do not clutter the hero section when rendered.
- `Release` stays repository-facing rather than Marketplace-facing.
- No screenshot should be added in a later step unless it reflects the current command surface exactly.

### Step 2: Restructure the Marketplace-facing README and supporting docs

Status:

- `Completed`

Purpose:

- improve the extension presentation while keeping claims accurate

Implementation notes:

- Reworked `extension/README.md` so the top of the page now follows a clearer scan order:
  - title + hero
  - compact badge row
  - one-paragraph value proposition
  - `Why trust this extension`
  - `Tested environments`
  - `What you can do`
  - command summary
  - quick start
- Pulled trust and validation signals higher on the page instead of burying them near the bottom.
- Separated rollback behavior and WSL notes into dedicated sections so the page reads less like a changelog dump.
- Kept the page factual and product-oriented without adding unsupported claims or vanity badges.

### Step 3: Add or refine supporting visual assets if needed

Status:

- `Completed`

Purpose:

- make the page feel more polished without introducing stale or misleading visuals

Implementation notes:

- Reviewed the current visual assets and kept the existing hero/icon set for this iteration.
- Current assets are already strong enough for Marketplace use:
  - `extension/media/hero.png`: `1600x640`
  - `extension/media/icon.png`: `256x256`
  - `docs/assets/codex-session-isolator-banner.svg` remains suitable for repository-facing use
- Deliberately did not add screenshots in this step.
- Reason: the command surface is now stable, but screenshots of prompts/flows still carry a higher stale-risk than the existing hero. For this release, a cleaner README structure gives better signal with lower maintenance cost.
- Result: visual polish improved through stronger layout and existing branded assets, without adding screenshot maintenance burden.

### Step 4: Align repository docs and packaging metadata

Status:

- `Completed`

Purpose:

- keep Marketplace-facing messaging aligned with root docs and release docs

Implementation notes:

- Synced repository-facing docs with the Marketplace presentation direction so trust and validation claims do not drift.
- Added a short `Why trust this project` block near the top of the root `README.md`.
- Added an explicit guidance note in `docs/TRUST.md` that public-facing docs must not imply support beyond the validated matrix.
- Added a `Recommended Marketplace page shape` section to `docs/MARKETPLACE.md` so future edits have a stable presentation standard.
- Kept packaging metadata unchanged in this step because the current `extension/package.json` fields already align with the intended Marketplace positioning.

### Step 5: Compare the result against this idea

Status:

- `Completed`

Purpose:

- verify that polish did not drift into overclaiming or clutter

Alignment review:

- `Match`: the Marketplace-facing README is now easier to scan and places trust/validation signals near the top.
- `Match`: badge usage stayed intentionally compact in the extension README and did not expand into low-signal vanity badges.
- `Match`: support boundaries are clearer through explicit validated-environment language in both Marketplace-facing and repository-facing docs.
- `Match`: visual polish improved without adding stale screenshots or overclaiming UI stability.
- `Match`: the root README, trust docs, and Marketplace-preparation docs are now aligned around the same presentation standard.
- `Accepted choice`: no new screenshot or extra trust badge was added in this iteration because the current hero already carries the visual weight and avoids new maintenance overhead.
- `Residual gap`: README rendering quality still needs a final human visual pass in VS Code Marketplace or a local Markdown preview before the final polish commit.

### Step 6: Prepare a user-review handoff

Status:

- `Completed`

Purpose:

- give a focused checklist for visual/trust review before final commit

User-review handoff:

- `Primary review surface`: preview `extension/README.md` as the Marketplace-facing page.
- `Secondary review surface`: confirm the root `README.md` and `docs/TRUST.md` tell the same trust story without duplicating every section.

Suggested review checklist:

1. `Top-of-page scan`
   - expected:
     - hero renders cleanly
     - badge row feels compact rather than crowded
     - the one-paragraph value proposition is understandable at a glance

2. `Trust clarity`
   - expected:
     - `Why trust this extension` reads concrete rather than promotional
     - no wording implies telemetry-free behavior beyond what the code/docs actually guarantee
     - project-scoped and reversible behavior are easy to notice near the top

3. `Validation clarity`
   - expected:
     - `Tested environments` is visible without scrolling too far
     - validated environments and best-effort environments are clearly distinguished
     - no platform claim appears broader than the current CI/manual coverage

4. `Command clarity`
   - expected:
     - the three primary commands are easy to spot
     - utility commands feel secondary, not equal-weight clutter

5. `Overall professionalism`
   - expected:
     - the page feels more intentional than before
     - nothing reads like internal changelog text
     - there is no obvious badge or section you would remove as noise

Known limitation before final commit:

- This step does not validate live Marketplace rendering; it prepares the final human review checklist only.

### Step 7: Final readiness review for commit

Status:

- `Completed`

Purpose:

- confirm the branch is ready for the final polish commit

Commit-readiness review:

- `Scope delivered`: the Marketplace-facing README was restructured, the badge strategy was tightened, trust/validation messaging was moved higher, and repository-facing docs were aligned with the same presentation standard.
- `Files touched in this feature`:
  - `extension/README.md`
  - `README.md`
  - `docs/TRUST.md`
  - `docs/MARKETPLACE.md`
  - this idea file
- `Change type`: documentation/presentation only; no launcher or extension runtime behavior changed in this feature.
- `Validation completed`:
  - direct consistency review against the idea
  - `git diff --check` on touched files
- `Remaining gap`: live Marketplace rendering was not validated in this environment; the remaining check is a human visual review of the rendered README.
- `Commit status`: ready for a final polish commit after user approval.
