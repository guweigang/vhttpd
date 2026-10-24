import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import {fileURLToPath} from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const pause = ms => new Promise(r => setTimeout(r, ms));
async function until(fn) { for (let i = 0; i < 200; i++) { const value = await fn(); if (value) return value; await pause(50); } throw new Error('condition timed out'); }
async function port() { const s = net.createServer(); await new Promise(r => s.listen(0, '127.0.0.1', r)); const p = s.address().port; await new Promise(r => s.close(r)); return p; }

test('real sent worker receipts cannot roll back a reserved/rebound or revoked PHP binding', {timeout: 60000}, async () => {
 const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-sent-'));
 const token = randomBytes(32).toString('hex'), publication = randomBytes(32).toString('hex');
 const socketPath = path.join(root, 'worker.sock');
 const receipts = [], workerSockets = new Set();
 let ws, child, done, output = '', counter = 0;
 const worker = net.createServer(socket => {
  workerSockets.add(socket); socket.on('close', () => workerSockets.delete(socket));
  let bytes = Buffer.alloc(0);
  socket.on('data', data => {
   bytes = Buffer.concat([bytes, data]);
   if (bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE(0)) return;
   const request = JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE(0)).toString());
   if (request.event_type === 'feishu.message.sent') receipts.push({request, receipt: JSON.parse(request.payload)});
   const body = Buffer.from(JSON.stringify({handled: true, commands: []}));
   const header = Buffer.alloc(4); header.writeUInt32BE(body.length); socket.end(Buffer.concat([header, body]));
  });
 });
 const api = http.createServer((req, res) => {
  req.resume();
  res.writeHead(200, {'Content-Type': 'application/json'});
  if (req.url.includes('tenant_access_token')) return res.end(JSON.stringify({code: 0, tenant_access_token: 'fixture', expire: 7200}));
  if (req.url.includes('/im/v1/messages')) return res.end(JSON.stringify({code: 0, data: {message_id: `physical-${++counter}`}}));
  res.end(JSON.stringify({code: 1, msg: 'no websocket fixture'}));
 });
 async function producer(action, values = {}) {
  const p = spawn('php', ['tests/protocol/feishu-sent-worker.php'], {cwd: repo, env: {...process.env, VHTTPD_BOT_DB_PATH: path.join(root, 'producer.sqlite')}});
  let out = '', err = ''; p.stdout.on('data', b => { out += b; }); p.stderr.on('data', b => { err += b; });
  p.stdin.end(JSON.stringify({action, ...values}));
  assert.equal(await new Promise(r => p.once('close', r)), 0, err);
  return JSON.parse(out);
 }
 try {
  await new Promise(r => worker.listen(socketPath, r));
  await new Promise(r => api.listen(0, '127.0.0.1', r));
  const web = await port(); let admin; do { admin = await port(); } while (admin === web);
  const config = path.join(root, 'hub.toml');
  fs.writeFileSync(config, `[server]\nhost="127.0.0.1"\nport=${web}\n[files]\npid_file="${root}/hub.pid"\nevent_log="${root}/events.ndjson"\n[worker]\nautostart=false\nsocket="${socketPath}"\n[admin]\nenabled=true\nhost="127.0.0.1"\nport=${admin}\ntoken="${token}"\non_data_plane=false\n[bridge]\nenabled=false\ntoken="${token}"\n`);
  child = spawn(binary, ['--config', config, '--executor', 'php', '--php-worker-entry', path.join(repo, 'tests/protocol/feishu-sent-worker.php'), '--worker-socket', socketPath, '--feishu-enabled', 'true', '--feishu-app-id', 'fixture', '--feishu-app-secret', 'fixture', '--feishu-open-base-url', `http://127.0.0.1:${api.address().port}/open-apis`], {cwd: repo});
  child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; }); done = new Promise(r => child.once('close', r));
  await until(async () => { assert.equal(child.exitCode, null, output); try { return (await fetch(`http://127.0.0.1:${admin}/health`)).ok && (await fetch(`http://127.0.0.1:${web}/health`)).ok; } catch { return false; } });
  ws = new WebSocket(`ws://127.0.0.1:${web}/bridge/ws?client_id=sent-fixture&token=${token}`);
  const pending = new Map();
  ws.addEventListener('message', event => { const reply = JSON.parse(String(event.data)); const cb = pending.get(reply.request_id); if (cb) { pending.delete(reply.request_id); cb(reply); } });
  await new Promise((r, j) => { ws.addEventListener('open', r, {once: true}); ws.addEventListener('error', j, {once: true}); });
  const call = (action, request) => new Promise((resolve, reject) => {
   const id = randomBytes(12).toString('hex'); const timer = setTimeout(() => { pending.delete(id); reject(new Error('bridge ' + action + ' timed out\n' + output)); }, 8000);
   pending.set(id, reply => { clearTimeout(timer); if (reply.ok !== true) reject(new Error('bridge ' + action + ': ' + JSON.stringify(reply))); else resolve(reply); });
   ws.send(JSON.stringify({type: 'feishu_proxy_request', request_id: id, action, request}));
  });
  const request = (generation = '', target = '', extra = {}) => ({provider: 'feishu', instance: 'main', target, target_type: target ? 'message_id' : '', text: 'content', message_type: 'interactive', content: JSON.stringify({elements: [{tag: 'markdown', content: '{{content}}'}]}), metadata: {stream_id: 'wire', stream_generation: generation, ...extra}});
  const lease = await call('create', request());
  await producer('create', {generation: lease.stream_generation, publication_id: publication});
  const sent = await call('send', {...request(lease.stream_generation, '', {creation_token: lease.creation_token, publication_id: publication}), target: 'chat', target_type: 'chat_id'});
  await call('finish', request(sent.stream_generation, sent.message_id));
  await call('append', request(sent.stream_generation, sent.message_id));
  await until(() => receipts.length === 1);
  const old = receipts[0].receipt;
  assert.equal(old.publication_id, publication); assert.equal(old.publication_sequence, 2);
  assert.equal(receipts[0].request.instance, 'main'); assert.equal(old.instance, 'main');
  const accepted = await producer('deliver', {receipt: old});
  assert.equal(accepted.row.response_message_id, old.message_id);
  const reservation = await producer('reserve');
  const pendingRow = reservation.row;
  assert.deepEqual((await producer('deliver', {receipt: {...old, publication_sequence: 99}})).row, pendingRow, 'late old result completed a pending rebind');
  const bound = await call('bind', request(sent.stream_generation, old.message_id, {...reservation.metadata, source_stream: 'wire', source_app: 'main'}));
  assert.notEqual(bound.stream_generation, sent.stream_generation);
  await call('append', request(bound.stream_generation, old.message_id));
  await call('finish', request(bound.stream_generation, old.message_id));
  await call('append', request(bound.stream_generation, old.message_id));
  await until(() => receipts.length === 2);
  const current = receipts[1].receipt;
  assert.equal(current.publication_id, reservation.metadata.publication_id); assert.equal(current.publication_sequence, 2);
  assert.equal(current.stream_generation, bound.stream_generation);
  const rebound = (await producer('deliver', {receipt: current})).row;
  assert.equal(rebound.response_message_id, current.message_id); assert.equal(rebound.stream_generation, bound.stream_generation);
  assert.deepEqual((await producer('deliver', {receipt: old})).row, rebound);
  const cancelled = (await producer('cancel')).row;
  await call('clear', request(bound.stream_generation));
  for (const receipt of [old, current, {...current, publication_sequence: 999}]) assert.deepEqual((await producer('deliver', {receipt})).row, cancelled);
  assert.equal(cancelled.stream_publication_id, ''); assert.equal(child.exitCode, null, output);
 } catch (error) {
  console.error(error.stack);
  console.error(output.slice(-5000));
  throw error;
 } finally {
  if (ws) ws.close();
  if (child && child.exitCode === null) { child.kill('SIGTERM'); const t = setTimeout(() => child.kill('SIGKILL'), 7000); await done; clearTimeout(t); }
  for (const s of workerSockets) s.destroy();
  await new Promise(r => worker.close(r)); await new Promise(r => api.close(r));
  fs.rmSync(root, {recursive: true, force: true});
 }
});
