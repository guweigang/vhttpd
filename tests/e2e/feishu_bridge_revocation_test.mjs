import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const pause = ms => new Promise(r => setTimeout(r, ms));
async function port() {
  const server = net.createServer();
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const value = server.address().port;
  await new Promise(r => server.close(r));
  return value;
}
async function until(fn, duration = 10000) {
  const deadline = Date.now() + duration;
  let last;
  while (Date.now() < deadline) {
    try { const value = await fn(); if (value) return value; } catch (e) { last = e; }
    await pause(50);
  }
  throw new Error('condition timed out: ' + (last?.message || 'not ready'));
}
async function connect(url) {
  const ws = new WebSocket(url);
  const pending = new Map();
  ws.addEventListener('message', event => {
    const result = JSON.parse(String(event.data));
    const callback = pending.get(result.request_id);
    if (callback) { pending.delete(result.request_id); callback(result); }
  });
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, {once: true}); ws.addEventListener('error', reject, {once: true}); });
  return {
    ws,
    call(action, request, requestId = randomBytes(12).toString('hex'), timeout = 4000) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(requestId); reject(new Error('bridge reply timeout: ' + action)); }, timeout);
        pending.set(requestId, result => { clearTimeout(timer); resolve(result); });
        ws.send(JSON.stringify({type: 'feishu_proxy_request', request_id: requestId, action, request}));
      });
    },
  };
}

test('cross-host bridge revoke: replacement, late HTTP, failed revoke/reconnect and lease expiry', {timeout: 120000}, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-bridge-revoke-'));
  const token = randomBytes(32).toString('hex');
  const children = [], sockets = [], tunnels = new Set();
  let proxy, proxyConnections = 0, dropWorkerReplies = false;
  let sends = 0, held, release;
  const api = http.createServer((req, res) => {
    const reply = body => { if (res.writableEnded || res.destroyed) return; res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
    if (req.url.includes('tenant_access_token')) return reply({code: 0, tenant_access_token: 'fixture-access', expire: 7200});
    if (req.url.includes('/im/v1/messages')) {
      req.resume();
      sends++;
      const message = 'message-' + sends;
      if (held) { held = false; release = () => reply({code: 0, data: {message_id: message}}); return; }
      return reply({code: 0, data: {message_id: message}});
    }
    return reply({code: 1, msg: 'no provider websocket in this fixture'});
  });
  await new Promise(r => api.listen(0, '127.0.0.1', r));
  async function start(name, extra = '', native = false) {
    const web = await port(), admin = await port();
    const config = path.join(root, name + '.toml');
    fs.writeFileSync(config, `[server]\nhost="127.0.0.1"\nport=${web}\n[files]\nevent_log="${root}/${name}.ndjson"\npid_file="${root}/${name}.pid"\n[worker]\nautostart=false\n[admin]\nenabled=true\nhost="127.0.0.1"\nport=${admin}\ntoken="${token}"\non_data_plane=false\n${extra}`);
    const args = ['--config', config];
    if (native) args.push('--feishu-enabled', 'true', '--feishu-app-id', 'fixture', '--feishu-app-secret', 'fixture-secret', '--feishu-open-base-url', `http://127.0.0.1:${api.address().port}/open-apis`);
    const child = spawn(binary, args, {cwd: repo, stdio: ['ignore', 'pipe', 'pipe']});
    let output = '';
    child.stdout.on('data', d => { output += d; }); child.stderr.on('data', d => { output += d; });
    const done = new Promise(r => child.once('close', r));
    children.push({child, done, output: () => output});
    await until(async () => {
      assert.equal(child.exitCode, null, output);
      if ((await fetch(`http://127.0.0.1:${admin}/health`)).status !== 200) return false;
      await fetch(`http://127.0.0.1:${web}/health`);
      return true;
    });
    return {web, admin};
  }
  const request = (stream, lease = {}, target = '') => ({provider: 'feishu', instance: 'main', target, target_type: target ? 'message_id' : '', text: 'hello', metadata: {stream_id: stream, stream_generation: lease.stream_generation || '', creation_token: lease.creation_token || ''}});
  async function peer(server, id) {
    const socket = await connect(`ws://127.0.0.1:${server.web}/bridge/ws?client_id=${id}&token=${token}`);
    sockets.push(socket.ws); return socket;
  }
  try {
    const server = await start('owner', `[bridge]\nenabled=false\ntoken="${token}"\n`, true);
    let first = await peer(server, 'peer');
    // First bind spends a target-bound grant; rebind uses the previous remote
    // generation and source scope, then publishes a fresh generation.
    const bindLease = await first.call('create', request('bind-old', {}, 'physical-bind'), 'bind-intent');
    assert.equal(bindLease.ok, true);
    const bindRequest = {...request('bind-old', {}, 'physical-bind'), metadata: {
      stream_id: 'bind-old', creation_generation: bindLease.stream_generation,
      creation_token: bindLease.creation_token, source_stream: 'bind-old', source_app: 'main',
    }};
    const bound = await first.call('bind', bindRequest);
    assert.equal(bound.ok, true, JSON.stringify(bound));
    assert.ok(bound.stream_generation);
    assert.equal((await first.call('append', request('bind-old', bound, 'physical-bind'))).ok, true);
    const preview = await first.call('finish', {...request('bind-old', bound, 'physical-bind'), metadata: {...request('bind-old', bound).metadata, feishu_stream_finish: 'false'}});
    assert.equal(preview.stream_generation, bound.stream_generation);
    assert.equal(preview.stream_state, 'open');
    const finished = await first.call('finish', request('bind-old', bound, 'physical-bind'));
    assert.equal(finished.stream_generation, bound.stream_generation);
    assert.equal(finished.stream_state, 'sealed');
    const destinationOwner = await peer(server, 'destination-owner');
    const destinationGrant = await destinationOwner.call('create', request('foreign-destination'), 'foreign-grant');
    assert.equal(destinationGrant.ok, true);
    assert.equal((await first.call('bind', {...request('foreign-destination', bound, 'physical-bind'), metadata: {
      stream_id: 'foreign-destination', stream_generation: bound.stream_generation,
      source_stream: 'bind-old', source_app: 'main',
    }})).ok, false, 'target CAS authorized a foreign destination');
    const destinationSend = await destinationOwner.call('send', {...request('foreign-destination', destinationGrant), target: 'chat', target_type: 'chat_id', message_type: 'text'});
    assert.equal(destinationSend.ok, true, "rebind revoked another connection's creation grant");
    await destinationOwner.call('clear', request('foreign-destination', destinationGrant));
    const rebindRequest = {...request('bind-new', bound, 'physical-bind'), metadata: {
      stream_id: 'bind-new', stream_generation: bound.stream_generation,
      source_stream: 'bind-old', source_app: 'main',
    }};
    const rebound = await first.call('bind', rebindRequest);
    assert.equal(rebound.ok, true, JSON.stringify(rebound));
    assert.notEqual(rebound.stream_generation, bound.stream_generation);
    assert.equal((await first.call('bind', rebindRequest)).ok, false, 'old rebind CAS replayed');
    assert.equal((await first.call('clear', request('bind-old', bound, 'physical-bind'))).ok, true);
    assert.equal((await first.call('append', request('bind-new', rebound, 'physical-bind'))).ok, true, 'old clear removed rebound generation');
    assert.equal((await first.call('append', request('bind-old', bound, 'physical-bind'))).ok, false);
    assert.equal((await first.call('clear', request('bind-new', rebound, 'physical-bind'))).ok, true);
    assert.equal((await first.call('bind', bindRequest)).ok, false, 'spent first bind revived after clear');
    const beforeBindClear = await first.call('create', request('bind-cleared', {}, 'cleared-physical'), 'bind-cleared');
    assert.equal(beforeBindClear.ok, true);
    await first.call('clear', request('bind-cleared', beforeBindClear, 'cleared-physical'));
    assert.equal((await first.call('bind', {...request('bind-cleared', {}, 'cleared-physical'), metadata: {
      stream_id: 'bind-cleared', creation_generation: beforeBindClear.stream_generation,
      creation_token: beforeBindClear.creation_token,
    }})).ok, false, 'clear-before-bind revived a revoked grant');
    const lease = await first.call('create', request('stream'), 'intent');
    assert.equal(lease.ok, true, JSON.stringify(lease));
    const send = {...request('stream', lease), target: 'chat', target_type: 'chat_id', message_type: 'text'};
    const sent = await first.call('send', send);
    assert.equal(sent.ok, true, JSON.stringify(sent));
    assert.equal((await first.call('clear', request('stream', lease))).ok, true);
    const replay = await first.call('create', request('stream'), 'intent');
    assert.equal(replay.creation_token, lease.creation_token, 'replayed create minted replacement authority');
    const count = sends;
    assert.equal((await first.call('send', send)).ok, false);
    assert.equal(sends, count);
    const next = await peer(server, 'peer');
    assert.equal((await next.call('send', send)).ok, false);
    const lateLease = await next.call('create', request('late'), 'late-intent');
    held = true; release = undefined;
    const late = next.call('send', {...request('late', lateLease), target: 'chat', target_type: 'chat_id', message_type: 'text'}, 'late-send', 2500).catch(() => null);
    await until(() => release);
    const replacement = await peer(server, 'peer');
    const fresh = await replacement.call('create', request('late'), 'fresh-intent');
    assert.equal(fresh.ok, true);
    const finishLate = release; release = undefined; finishLate(); await late;
    assert.equal((await replacement.call('append', request('late', lateLease, 'message-' + sends))).ok, false, 'late HTTP restored the old buffer');
    const good = await replacement.call('send', {...request('late', fresh), target: 'chat', target_type: 'chat_id', message_type: 'text'});
    assert.equal(good.ok, true, JSON.stringify(good));
    replacement.ws.close();
    const again = await peer(server, 'peer');
    assert.equal((await again.call('append', request('late', fresh, good.message_id))).ok, false, 'disconnected buffer survived reconnect');
    // A fail retires the actual rollover chain, not only the root ID.
    const failurePeer = await peer(server, 'failure');
    const failureLease = await failurePeer.call('create', request('failure'), 'failure-create');
    const failureSent = await failurePeer.call('send', {...request('failure', failureLease), target: 'chat', target_type: 'chat_id', message_type: 'text'});
    assert.equal(failureSent.ok, true);
    assert.equal((await failurePeer.call('finish', request('failure', failureSent, failureSent.message_id))).stream_state, 'sealed');
    const rollover = await failurePeer.call('append', request('failure', failureSent, failureSent.message_id));
    assert.equal(rollover.ok, true);
    const childId = 'message-' + sends;
    assert.notEqual(childId, failureSent.message_id);
    const failed = await failurePeer.call('fail', {...request('failure', failureSent, failureSent.message_id), message_type: 'interactive', content: JSON.stringify({elements: [{tag: 'markdown', content: 'failed'}]})});
    assert.equal(failed.ok, true, JSON.stringify(failed));
    assert.equal(failed.stream_generation, failureSent.stream_generation);
    assert.equal(failed.stream_state, 'removed');
    assert.equal((await failurePeer.call('append', request('failure', failureSent, childId))).ok, false, 'failed root left a live successor');

    // Old HTTP may finish physically, but cannot publish into a same-ID buffer
    // installed by a replacement connection while that HTTP was in flight.
    for (const action of ['finish', 'fail']) {
      const id = 'late-' + action;
      const oldPeer = await peer(server, id);
      const oldLease = await oldPeer.call('create', request(id), 'create-' + id);
      const oldSent = await oldPeer.call('send', {...request(id, oldLease), target: 'chat', target_type: 'chat_id', message_type: 'text'});
      assert.equal(oldSent.ok, true);
      held = true; release = undefined;
      const oldResult = oldPeer.call(action, {...request(id, oldSent, oldSent.message_id), message_type: 'interactive', content: JSON.stringify({elements: [{tag: 'markdown', content: 'failed'}]})}, id + '-operation', 2500).catch(() => null);
      await until(() => release);
      const currentPeer = await peer(server, id);
      const currentGrant = await currentPeer.call('create', request(id, {}, oldSent.message_id), id + '-replacement');
      assert.equal(currentGrant.ok, true);
      const current = await currentPeer.call('bind', {...request(id, {}, oldSent.message_id), metadata: {stream_id: id, creation_generation: currentGrant.stream_generation, creation_token: currentGrant.creation_token}});
      assert.equal(current.ok, true);
      const finishHttp = release; release = undefined; finishHttp();
      await oldResult;
      const afterLate = await currentPeer.call('append', request(id, current, oldSent.message_id));
      assert.equal(afterLate.ok, true, action + ' completion removed replacement');
      assert.equal(afterLate.stream_generation, current.stream_generation);
      assert.equal(afterLate.stream_state, 'open', action + ' completion sealed replacement');
      await currentPeer.call('clear', request(id, current, oldSent.message_id));
    }
    proxy = net.createServer(downstream => {
      proxyConnections++;
      if (dropWorkerReplies) dropWorkerReplies = false;
      const upstream = net.connect(server.web, '127.0.0.1');
      tunnels.add(downstream); tunnels.add(upstream);
      downstream.pipe(upstream);
      upstream.on('data', data => { if (!dropWorkerReplies) downstream.write(data); });
      upstream.on('error', () => downstream.destroy());
      downstream.on('error', () => upstream.destroy());
      downstream.on('close', () => { tunnels.delete(downstream); upstream.destroy(); });
      upstream.on('close', () => { tunnels.delete(upstream); downstream.destroy(); });
    });
    await new Promise(r => proxy.listen(0, '127.0.0.1', r));
    const worker = await start('worker', `[bridge]\nenabled=true\nws_url="ws://127.0.0.1:${proxy.address().port}/bridge/ws"\nclient_id="worker"\ntoken="${token}"\n`);
    const origin = `http://127.0.0.1:${worker.admin}`;
    const route = '/admin/runtime/feishu/creation';
    const admin = async (method, suffix = '', body) => {
      const res = await fetch(origin + route + suffix, {method, headers: {'x-vhttpd-admin-token': token, 'Content-Type': 'application/json'}, body: body && JSON.stringify(body), signal: AbortSignal.timeout(10000)});
      return {status: res.status, body: await res.json()};
    };
    const discovery = (await admin('GET')).body;
    const intent = id => ({...discovery, request_id: id.repeat(64), stream_id: 'worker-stream', instance: 'main', kind: 'send', message_id: ''});
    let originalIntent;
    const issued = await until(async () => { originalIntent = {...intent('a'), request_id: randomBytes(32).toString('hex')}; const r = await admin('POST', '', originalIntent); return r.status === 200 ? r : null; });
    assert.match(issued.body.token, /^[a-f0-9]{64}$/);
    // Replacement invalidates the server authority while the old worker socket
    // remains readable. Its revoke times out, forcing that precise socket closed.
    await peer(server, 'worker');
    assert.equal((await admin('POST', '/revoke', originalIntent)).status, 503);
    assert.equal((await admin('POST', '', originalIntent)).status, 409);
    let freshIntent;
    const newIssued = await until(async () => {
      freshIntent = {...discovery, request_id: randomBytes(32).toString('hex'), stream_id: 'worker-fresh', instance: 'main', kind: 'send', message_id: ''};
      const r = await admin('POST', '', freshIntent); return r.status === 200 ? r : null;
    }, 12000);
    assert.notEqual(newIssued.body.token, issued.body.token);
    assert.equal((await admin('POST', '/revoke', originalIntent)).status, 503);
    assert.equal((await admin('POST', '/revoke', freshIntent)).status, 200, 'old revoke retired replacement connection');
    const previousConnections = proxyConnections;
    dropWorkerReplies = true;
    const silent = await peer(server, 'silent');
    const expiring = await silent.call('create', request('silent'), 'silent-intent');
    assert.equal(expiring.ok, true);
    await Promise.all([until(() => silent.ws.readyState === WebSocket.CLOSED, 48000), until(() => proxyConnections > previousConnections, 55000)]);
    let afterPartition;
    await until(async () => {
      afterPartition = {...intent('c'), request_id: randomBytes(32).toString('hex'), stream_id: 'after-partition'};
      return (await admin('POST', '', afterPartition)).status === 200;
    });
    assert.equal((await admin('POST', '/revoke', afterPartition)).status, 200);
    const afterExpiry = await peer(server, 'silent');
    assert.equal((await afterExpiry.call('send', {...request('silent', expiring), target: 'chat', target_type: 'chat_id', message_type: 'text'})).ok, false);
    assert.equal((await afterExpiry.call('create', request('silent'), 'silent-intent')).ok, true);
  } catch (error) {
    throw new Error(String(error?.stack || error) + '\n' + children.map(p => p.output().replaceAll(token, '[redacted]')).join('\n'));
  } finally {
    if (release) release();
    for (const ws of sockets) ws.close();
    for (const {child, done} of children.reverse()) {
      if (child.exitCode === null) child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 7000);
      await done; clearTimeout(timer);
    }
    for (const socket of tunnels) socket.destroy();
    if (proxy) await new Promise(r => proxy.close(r));
    api.closeAllConnections();
    await new Promise(r => api.close(r));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
