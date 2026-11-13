import {storageChecks} from './storage-e2e-checks.mjs';
// Real vhttpd/vjsx HTTP + disposable PostgreSQL checks. Execute via e2e.sh.
import {assert} from './support.mjs';
import {execFileSync} from 'child_process';
import {readFileSync, writeFileSync} from 'node:fs';
if (process.release?.name !== 'vjsx') throw Error('Run E2E with vjsx');
const base = process.env.WCF_BASE_URL;
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(base || '')) throw Error('loopback WCF_BASE_URL required');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const state = process.env.WCF_TEST_STATE;
const sql = statement => execFileSync(process.env.WCF_PSQL, ['-h', '127.0.0.1', '-p', process.env.WCF_DB_PORT,
  '-U', 'wcf_local', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', statement], {encoding: 'utf8'}).trim();
async function request(path, data = {}, token, expected = 200) {
  const response = await fetch(base + path, {method: 'POST', body: JSON.stringify(data),
    headers: {'content-type': 'application/json', ...(token ? {authorization: 'Bearer ' + token} : {})},
    signal: AbortSignal.timeout(15000)});
  const text = await response.text();
  for (const secret of ['local-only-not-a-secret', 'PRIVATE_ERROR_MUST_NOT_LEAK', 'local-unused']) assert.ok(!text.includes(secret));
  assert.equal(response.status, expected, path + ': HTTP ' + response.status + ' ' + text);
  return JSON.parse(text);
}
const until = Date.now() + 2 * Number(process.env.VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS || 120000) + 15000;
let ready = false;
while (Date.now() < until) {
  try { const response = await fetch(base + '/', {signal: AbortSignal.timeout(1000)}); if (response.status === 405) { ready = true; break; } }
  catch (_) {}
  await pause(500);
}
assert.ok(ready, 'server did not become ready');
if (process.env.WCF_TEST_PHASE === 'persist') {
  const {token, storage} = JSON.parse(readFileSync(state, 'utf8'));
  const file = await fetch(storage.url); assert.equal(file.status, 200);
  assert.equal(await file.text(), 'restart');
  const removed = await fetch(base + '/storage/delete', {method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+token},body:JSON.stringify({fileList:[storage.fileID]})});
  assert.equal(removed.status,200); assert.equal((await fetch(storage.url)).status,404);
  const {result} = await request('/functions/getUser', {}, token);
  assert.equal(result.openid, 'bob'); assert.equal(result.user.display_name, 'Bobby');
  await request('/functions/cloudContract', {}, token, 404);
  console.log('PASS production entry: persisted session/document; test functions absent');
} else {
  const alice = (await request('/auth/login', {code: 'alice'})).token;
  const bob = (await request('/auth/login', {code: 'bob'})).token;
  assert.notEqual(alice, bob);
  await request('/auth/login', {code: 'bad'}, undefined, 401);
  await request('/functions/getUser', {openid: 'alice'}, undefined, 401);
  await request('/functions/getUser', {}, 'a'.repeat(64), 401);
  let overlaps = 0;
  for (let round = 0; round < 2; round++) {
    const batch = await Promise.all(Array.from({length: 8}, (_, i) => i % 2 ? ['alice', alice] : ['bob', bob]).map(async ([who, token]) => {
      const {result} = await request('/functions/cloudIdentity', {openid: 'forged', APPID: 'evil', context: {OPENID: 'forged'}}, token);
      assert.equal(result.before.OPENID, who); assert.equal(result.after.OPENID, who);
      assert.equal(result.nested.openid, who); assert.equal(result.eventOpenid, who);
      return result;
    }));
    assert.ok(new Set(batch.map(item => item.laneId)).size > 1);
    for (let i = 0; i < batch.length; i++) for (let j = i + 1; j < batch.length; j++) {
      const a = batch[i], b = batch[j];
      if (a.laneId !== b.laneId && a.startedAt < b.finishedAt && b.startedAt < a.finishedAt) overlaps++;
    }
  }
  assert.ok(overlaps > 0, 'no measured cross-lane overlap');
  console.log('PASS auth, forged identity, nested functions, cross-lane overlap (' + overlaps + ')');
  const storageState = await storageChecks(base, alice, bob);
  const action = async (action, data = {}, status = 200) => (await request('/functions/cloudContract', {action, ...data}, bob, status)).result;
  await action('seed'); await request('/functions/cloudContract', {action: 'seed'}, alice);
  await Promise.all(Array.from({length: 8}, () => action('inc')));
  const document = await action('read');
  assert.equal(document.visits, 8); assert.equal(document.nested.count, 17); assert.equal(document.nested.other, 'value');
  const query = await action('query');
  assert.equal(query.data.length, 1); assert.equal(query.count.total, 1); assert.equal(query.missing, 2);
  const operators = await action('operators');
  assert.equal(operators.either, 2); assert.equal(operators.member, 1); assert.equal(operators.excluded, 1);
  assert.equal(operators.unequal, 1); assert.equal(operators.array, 2); assert.equal(operators.mixedType, 0);
  assert.deepEqual(operators.doc.nested, {count: 17, label: 'safe'}); assert.equal(operators.doc.missing, undefined);
  assert.equal(await action('tx'), 8); assert.equal((await action('read')).visits, 18);
  await action('tx', {fail: true}, 500); assert.equal((await action('read')).visits, 18);
  await action('ordinaryFailure', {}, 500); assert.equal((await action('read')).visits, 19);
  for (const name of ['cloudTimeout', 'cloudLate']) {
    await request('/functions/' + name, {}, bob, 504);
    assert.equal(sql("SELECT body->>'visits' FROM wcf_documents WHERE collection_name='contract' AND doc_id='bob'"), '19');
  }
  await pause(1100); assert.equal((await action('read')).visits, 19);
  const attack = "'); DROP TABLE wcf_documents; --";
  assert.ok((await action('add', {value: attack}))._id);
  assert.equal((await action('injection', {value: attack})).data.length, 1);
  await action('missing', {}, 404); await action('storage', {}, 400);
  assert.equal((await action('remove')).stats.removed, 2); assert.equal(await action('read'), null);
  console.log('PASS JSONB CRUD/operators, atomic increments, transaction rollback, late write rejection');
  const {result} = await request('/functions/updateProfile', {displayName: 'Bobby', OPENID: 'alice'}, bob);
  assert.equal(result.openid, 'bob'); assert.equal(result.user.display_name, 'Bobby');
  writeFileSync(state, JSON.stringify({token: bob, storage: storageState}));
}
