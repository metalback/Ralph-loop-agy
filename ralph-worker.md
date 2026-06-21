# ralph-worker

Autonomous engineering skill for the **Ralph Loop**. This file is loaded
by the `agy` agent inside the `ralph-loop-base` Docker sandbox via:

```
agy --load-skill ralph-worker
```

The Ralph Loop orchestrator (`ralph_runner.sh`) drives agy, appends a
fresh `progress.log` entry on each failure, and re-invokes this skill
until the validation command exits 0 or the circuit breaker trips.

## 1. Context loading (do this FIRST, before any code change)

Before touching a single file, read both of these from the project root:

1. **`PRD.md`** — the task definition. It states the goal and, critically,
   the `TEST_CMD` (validation command) that defines "done". Do not start
   coding until you understand both the goal and what success looks like.
2. **`progress.log`** — the history of previous attempts. Every entry
   includes the iteration number, the approach that was tried, and the
   stderr captured from the validation run. Read it carefully and **do
   not repeat the same approach that already failed**.

If `progress.log` is empty or missing, this is your first attempt — there
is no prior context to learn from. If it exists, treat it as a hard
constraint: a different approach is mandatory.

## 2. Workflow

1. Read `PRD.md` and `progress.log` (see §1).
2. Modify the code needed to satisfy the task. Stay within the project
   root; do not touch anything outside `/workspace`.
3. Run the validation command **exactly as specified in `PRD.md`** under
   `TEST_CMD`. Capture the exit code, stdout, and stderr.
4. Branch on the result:
   - **Exit 0** → success. Emit the success output format (§3).
   - **Exit non-zero** → failure. Analyze the error, propose a different
     approach in your final response, and emit the failure output
     format (§3).
5. Do not commit, do not push, do not modify `progress.log` or `PRD.md` —
   the orchestrator owns those files.

## 3. Output format (the orchestrator parses this)

Your final response **must** end with a single status line on its own
line, in one of these two forms:

- `RALPH_STATUS: SUCCESS` — when the validation command exits 0.
- `RALPH_STATUS: FAILURE: <one-line summary of what went wrong>` — when
  the validation command exits non-zero.

The `<one-line summary>` should be a single short line (≤ 120 chars)
describing the new approach you would try next, so the orchestrator can
append it to `progress.log` and feed it back into the next iteration.

Anything before the status line is free-form reasoning, but keep it
focused: the orchestrator only reads the final status line.

## 4. Hard constraints

- **Never** edit `PRD.md`, `progress.log`, or any orchestrator state.
- **Never** skip the validation step, even if the change looks obviously
  correct. The orchestrator decides success/failure from the exit code.
- **Never** repeat an approach that already failed in `progress.log`
  without a concrete reason why it will work this time.
- **Never** exit without a `RALPH_STATUS:` line — the orchestrator will
  treat a missing status line as a failure and waste an iteration.
- Stay within the project root mounted at `/workspace`. Do not modify
  host files, credentials, or anything outside the workspace.

## 5. Quick checklist before emitting the status line

- [ ] I read `PRD.md` and identified the `TEST_CMD`.
- [ ] I read `progress.log` (or confirmed it is empty/missing).
- [ ] My change follows an approach not yet tried (or has a concrete
      reason to retry a prior approach).
- [ ] I ran `TEST_CMD` and captured its exit code.
- [ ] My final line is `RALPH_STATUS: SUCCESS` or
      `RALPH_STATUS: FAILURE: <summary>`.
