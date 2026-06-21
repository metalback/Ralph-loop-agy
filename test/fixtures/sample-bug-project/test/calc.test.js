const test = require('node:test');
const assert = require('node:assert/strict');
const { multiply, divide } = require('../src/calc');

test('multiply 2 * 3 equals 6', () => {
  assert.equal(multiply(2, 3), 6);
});

test('multiply 0 * 5 equals 0', () => {
  assert.equal(multiply(0, 5), 0);
});

test('multiply negative numbers', () => {
  assert.equal(multiply(-4, 7), -28);
});

test('divide 10 / 2 equals 5', () => {
  assert.equal(divide(10, 2), 5);
});

test('divide by zero throws', () => {
  assert.throws(() => divide(1, 0), /division by zero/);
});
