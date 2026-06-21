const test = require('node:test');
const assert = require('node:assert/strict');
const { add, subtract } = require('../src/math');

test('add 2 + 3 equals 5', () => {
  assert.equal(add(2, 3), 5);
});

test('subtract 5 - 3 equals 2', () => {
  assert.equal(subtract(5, 3), 2);
});
