# Ralph-loop-agy

Hands-off autonomous engineering loop driven by [Antigravity CLI (agy)](https://www.npmjs.com/package/agy)
and the [Sandcastle](https://github.com/anomalyco/sandcastle) flow. An
orchestrator (`ralph_runner.sh`) runs `agy` inside a Docker sandbox,
validates the agent's changes against a `TEST_CMD` declared in `PRD.md`,
auto-commits successful iterations to a feature branch, and merges back
to the base branch at the end — with a circuit breaker that preserves
`progress.log` after `MAX_ITERATIONS` failed attempts.

## Status

| Stage | Description | Issue |
| --- | --- | --- |
| S1 | Docker sandbox + agy smoke test | #2 |
| S2 | `ralph-worker.md` skill + manual execution | #3 |
| S3 | Bash orchestrator + smoke test | #4 |
| S4 | Git automation (branch + commit + merge) | #5 |
| S5 | **E2E stress test with a real bug** | #6 |

## Repository layout

```
PRD.md                     # the PRD that drives the loop
ralph_runner.sh            # the Bash orchestrator
ralph-worker.md            # the skill loaded by agy
.sandcastle/               # sandcastle prompts, Dockerfile, test suites
  Dockerfile
  smoke-test.sh            # S1 — image acceptance criteria
  skill-test.sh            # S2 — ralph-worker.md acceptance criteria
  runner-test.sh           # S3/S4 — orchestrator + git helpers
  e2e-test.sh              # S5 — end-to-end stress test (issue #6)
test/fixtures/             # S5 — fixture project used by the E2E test
  sample-bug-project/      # real Node.js project with a real bug
  e2e-harness.sh           # driver that exercises the ralph_runner.sh loop
  agents/
    mock-agy-resolvable.sh # mock agy that fixes the bug in 1 iteration
    mock-agy-irresoluble.sh# mock agy that never fixes the bug
```

## How it works

1. `ralph_runner.sh` reads `PRD.md`, extracts `TEST_CMD` (or falls back
   to a stack-detection heuristic) and `BASE_BRANCH` / `ISSUE_ID` /
   `ISSUE_SLUG` from the current sandcastle branch.
2. It records the current commit as a baseline so it can stage only
   the files `agy` changes.
3. Each iteration:
   - Runs `agy --non-interactive --load-skill ralph-worker` inside the
     `ralph-loop-base` Docker sandbox, with the project mounted `:rw`
     and the host's agy credentials mounted `:ro`.
   - If `agy` produced code changes, runs `TEST_CMD` via `bash -c`.
   - On exit 0: creates the `ralph/issue-N-slug` feature branch (first
     success only) and commits with the `RALPH:` prefix.
   - On non-zero exit: appends the iteration to `progress.log`, waits
     `COOLDOWN_SECONDS`, retries.
4. After the first success, merges the feature branch into the base
   branch with `git merge --no-ff` (aborting cleanly on conflict).
5. After `MAX_ITERATIONS` failures: circuit breaker trips, the
   orchestrator exits 1, and `progress.log` is left intact for
   post-mortem.

## Configuration

All defaults are environment-overridable. A local `.env` is auto-sourced
when present. See `.sandcastle/.env.template` for the full list
(`MODEL`, `MAX_ITERATIONS`, `COOLDOWN_SECONDS`, `OPENCODE_BASE_URL`,
`OPENCODE_API_KEY`, `GH_TOKEN`).

## Testing

The project ships with four test suites, all Bash and dependency-free
besides `bash` and `git` (Docker is only required for the manual
`agy` invocation in the dynamic checks):

```bash
npm run test:smoke   # S1 — Dockerfile static + dynamic (image build/run)
npm run test:skill   # S2 — ralph-worker.md skill content
npm run test:runner  # S3/S4 — ralph_runner.sh static + git helpers
npm run test:e2e     # S5 — end-to-end stress test (resolvable + circuit-breaker)
npm test             # runs all four in order
```

The S5 suite (`npm run test:e2e`) is the most thorough: it copies the
fixture project under `test/fixtures/sample-bug-project/` into a
scratch git repo, drives the real `ralph_runner.sh` loop (sourcing it
for the git helpers) using a mock `agy`, and asserts that:

- The fixture has a real bug and a failing test out of the box.
- A resolvable bug is fixed in ≤ 5 iterations.
- A `RALPH:` commit is created on a `ralph/issue-N-slug` feature
  branch and merged back to the base branch.
- An irresoluble bug trips the circuit breaker after exactly 10
  iterations.
- `progress.log` accumulates one timestamped entry per failed
  attempt.
- The agy credentials path is mounted `:ro` (a live bind mount blocks
  writes; the test falls back to a `chmod 444` file when it cannot
  mount).

### S5 fixture project

`test/fixtures/sample-bug-project/` is a tiny CommonJS Node project
with a real bug: `multiply(a, b)` in `src/calc.js` returns `a + b`
instead of `a * b`. `PRD.md` declares the task and the `TEST_CMD`
(`npm test`); the two mock agents under `test/fixtures/agents/`
substitute for the real `agy` so the E2E test can run without Docker
or a Google credential.

The S5 suite is the only one that requires `node` to be on `PATH` and
`python3` to be available (the irresoluble mock uses a small Python
one-liner to replace the `multiply` body — `bash` + `sed` was not
expressive enough for the regex).
