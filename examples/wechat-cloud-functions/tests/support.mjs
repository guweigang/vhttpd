// Small assertion/registration harness for vjsx; no Node test or VM dependency.
import path from 'node:path';

export const exampleRoot = process.env.WCF_EXAMPLE_ROOT || path.resolve(path.dirname(process.argv[1]), '..');
const cases = [];
export default function test(label, callback) { cases.push({label, callback}); }
function fail(message = 'assertion failed') { throw new Error(message); }
function matches(error, expected) {
  if (expected === undefined) return true;
  if (expected instanceof RegExp) return expected.test(String(error.message || error));
  return typeof expected === 'function' && expected(error) === true;
}
function same(a, b) {
  if (Object.is(a, b)) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
  const left = Object.keys(a).sort(), right = Object.keys(b).sort();
  return left.length === right.length && left.every((key, index) => key === right[index] && same(a[key], b[key]));
}
export const assert = {
  fail,
  ok(value, message) { if (!value) fail(message); },
  equal(actual, expected, message) { if (!Object.is(actual, expected)) fail(message || 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual)); },
  strictEqual(actual, expected, message) { assert.equal(actual, expected, message); },
  notEqual(actual, expected, message) { if (Object.is(actual, expected)) fail(message || 'values must differ'); },
  deepEqual(actual, expected, message) { if (!same(actual, expected)) fail(message || 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual)); },
  match(value, pattern) { if (!pattern.test(value)) fail('value did not match ' + pattern); },
  throws(callback, expected) {
    try { callback(); } catch (error) { if (matches(error, expected)) return; throw error; }
    fail('expected an exception');
  },
  async rejects(promise, expected) {
    try { await (typeof promise === 'function' ? promise() : promise); }
    catch (error) { if (matches(error, expected)) return; throw error; }
    fail('expected a rejection');
  },
};
export async function run() {
  let failures = 0;
  for (const {label, callback} of cases) {
    try { await callback(); console.log('PASS ' + label); }
    catch (error) { failures++; console.error('FAIL ' + label + ': ' + String(error) + '\n' + (error.stack || '')); }
  }
  console.log(cases.length + ' tests, ' + failures + ' failures (vjsx)');
  if (failures) throw new Error('test suite failed');
}
