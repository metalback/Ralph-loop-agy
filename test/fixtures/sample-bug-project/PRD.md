# PRD: Fix the `multiply` function in `src/calc.js`

## Problem

The `multiply` function in `src/calc.js` is broken. It currently returns
the sum of its arguments instead of the product. As a result, every
caller of `multiply` gets the wrong answer.

## Task

Make `multiply(a, b)` return `a * b` for all integer inputs, including
`0` and negatives. The function must continue to be a regular CommonJS
export from `src/calc.js` so the existing `require('../src/calc')`
imports in `test/calc.test.js` keep working.

## Constraints

- Only modify `src/calc.js`. Do not touch `src/math.js`, the tests, or
  any other file. The test file is the source of truth for the contract.
- Keep the function signature (`function multiply(a, b)`) and the
  CommonJS module shape.
- Do not edit `PRD.md` or `progress.log` — the orchestrator owns those.

## Validation

The `TEST_CMD` below must exit 0 once the bug is fixed. Run it from the
project root.

TEST_CMD: npm test
