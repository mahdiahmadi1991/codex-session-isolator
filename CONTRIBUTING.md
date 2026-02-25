# Contributing

Thanks for contributing.

## Development flow

1. Fork the repository.
2. Create a branch from `pre-release`.
3. Make focused changes.
4. Run manual scenarios in `docs/TESTING.md`.
5. Open a pull request targeting `pre-release` with:
   - problem statement
   - approach
   - test evidence
6. Promote to `main` only via a pull request from `pre-release`.

## Branch policy

- `pre-release` is the integration branch for all feature/fix work.
- `main` accepts promotion PRs from `pre-release` only.
- Emergency exception:
  - create hotfix branch from `main` (for example: `hotfix/<issue-id>`)
  - open PR to `main` from that hotfix branch
  - add label `allow-main-hotfix`
  - after merge, open sync PR `main` -> `pre-release`

## Guidelines

- Keep changes cross-platform where possible.
- Do not hardcode user-specific paths.
- Preserve default Codex behavior when launcher is not used.
- Keep docs updated when behavior changes.

## Commit style

Use clear, scoped commit messages, for example:

- `feat: support WSL UNC workspace paths`
- `fix: handle missing code command in WSL`
- `docs: expand test matrix`
