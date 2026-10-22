import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function port() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const value = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return value;
}
async function until(fn) {
  let last;
  for (let i = 0; i < 60; i++) {
    try { if (await fn()) return; } catch (error) { last = error; }
    await pause(50);
  }
  throw new Error('Timed out: ' + (last?.message || 'condition not met'));
}

async function relayClient(port, messages) {
  const request = http.request({host:'127.0.0.1', port, path:'/relay?request_id=shared-request', headers:{
    connection:'Upgrade', upgrade:'websocket', 'sec-websocket-version':'13',
    'sec-websocket-key':'dGhlIHNhbXBsZSBub25jZQ=='
  }});
  const upgraded = new Promise((resolve, reject) => {
    request.once('error', reject);
    request.once('response', response => { response.resume(); reject(new Error(`Upgrade returned ${response.statusCode}`)); });
    request.once('upgrade', (response, socket, head) => resolve({socket, head}));
  });
  request.setTimeout(1000, () => request.destroy(new Error('Relay upgrade timed out')));
  request.end();
  const {socket, head} = await upgraded;
  let pending = Buffer.alloc(0);
  function consume(chunk) {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 2) {
      const opcode = pending[0] & 15;
      let length = pending[1] & 127, offset = 2;
      if (length === 126) {
        if (pending.length < 4) return;
        length = pending.readUInt16BE(2); offset = 4;
      }
      assert(length !== 127, 'fixture expects frames shorter than 65536 bytes');
      if (pending.length < offset + length) return;
      const body = pending.subarray(offset, offset + length);
      pending = pending.subarray(offset + length);
      if (opcode === 1) messages.push(JSON.parse(body.toString()));
    }
  }
  socket.on('data', consume);
  socket.on('error', error => messages.push({transport_error:error.message}));
  if (head.length) consume(head);
  return {
    send(payload) {
      const body = Buffer.from(payload), mask = Buffer.from([1,2,3,4]);
      const header = body.length < 126 ? Buffer.from([0x81, 0x80 | body.length]) : Buffer.from([0x81, 0xfe, body.length >> 8, body.length & 255]);
      socket.write(Buffer.concat([header, mask, Buffer.from(body.map((byte, i) => byte ^ mask[i % 4]))]));
    },
    close() { socket.destroy(); }
  };
}

async function verifyRegistration(t, concurrent = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-relay-identity-'));
  const relayPort = await port();
  let adminPort; do { adminPort = await port(); } while (adminPort === relayPort);
  const config = path.join(root, 'vhttpd.toml');
  fs.writeFileSync(config, `version=2
[server]
pid_file="${root}/runtime.pid"
[listeners.relay]
protocol="websocket"
transport="tcp"
host="127.0.0.1"
port=${relayPort}
[listeners.admin]
protocol="http"
transport="tcp"
host="127.0.0.1"
port=${adminPort}
[control]
listener="listener:admin"
token="identity-test"
[relays.edge]
mode="hub"
carrier="websocket"
listener="listener:relay"
path="/relay"
token="pair-test"
node_id="hub"
`);
  const child = spawn(binary, ['--config', config], {cwd:repo, env:{...process.env,VHTTPD_LOG_LEVEL:'info'}, stdio:['ignore','pipe','pipe']});
  const closed = once(child, 'close');
  let log = '', failed = true;
  const count = concurrent ? 16 : 2;
  const clients = [], messages = Array.from({length:count}, () => []);
  const waitUntil = fn => until(async () => {
    assert(child.exitCode === null && child.signalCode === null,
      `Hub exited: code=${child.exitCode}, signal=${child.signalCode}\n${log}`);
    return fn();
  });
  child.stdout.on('data', data => log = (log + data).slice(-100000));
  child.stderr.on('data', data => log = (log + data).slice(-100000));
  try {
    await waitUntil(async () => (await fetch(`http://127.0.0.1:${adminPort}/admin/runtime`, {headers:{'x-vhttpd-admin-token':'identity-test'}, signal:AbortSignal.timeout(500)})).ok);
    // Open all sockets before any hello: this deterministically overwrites
    // the first HubConn on the old implementation, without relying on a clock collision.
    for (let i = 0; i < count; i++) {
      await waitUntil(async () => {
        clients.push(await relayClient(relayPort, messages[i]));
        return true;
      });
    }
    for (let i = 0; i < count; i++) {
      clients[i].send(JSON.stringify({version:1, kind:'hello', id:`hello-${i}`, trace_id:`trace-${i}`,
        metadata:{node_id:`node-${i}`, relay_id:'edge', mode:'agent', carrier:'websocket', max_channels:'2'},
        headers:{authorization:'Bearer pair-test'}}));
      if (!concurrent) await waitUntil(() => messages[i].some(frame => frame.kind === 'hello_ack'));
    }
    await waitUntil(() => messages.every(frames => frames.some(frame => frame.kind === 'hello_ack')));
    for (let i = 0; i < count; i++) {
      assert.deepEqual(messages[i].filter(frame => frame.kind === 'hello_ack').map(frame => frame.metadata.node_id), [`node-${i}`]);
    }
    // A successful ACK is insufficient: the next admin request must still work.
    const response = await fetch(`http://127.0.0.1:${adminPort}/admin/runtime`, {headers:{'x-vhttpd-admin-token':'identity-test'}, signal:AbortSignal.timeout(1000)});
    assert(response.ok, `Admin runtime returned ${response.status}`);
    await response.arrayBuffer();
    await waitUntil(() => log.includes('request_id=shared-request'));
    failed = false;
  } finally {
    for (const client of clients) client.close();
    const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
    const stoppedByTest = child.exitCode === null && child.signalCode === null;
    if (stoppedByTest) child.kill('SIGTERM');
    const [code, signal] = await closed;
    if (!stoppedByTest) t.diagnostic(`Hub exit: code=${code}, signal=${signal}`);
    clearTimeout(timer);
    if (failed || process.env.VHTTPD_E2E_KEEP_TMP === '1') {
      fs.writeFileSync(path.join(root, 'exit.json'), JSON.stringify({code, signal, stoppedByTest}, null, 2));
      fs.writeFileSync(path.join(root, 'server.log'), log);
      fs.writeFileSync(path.join(root, 'messages.json'), JSON.stringify(messages, null, 2));
      t.diagnostic(`Relay identity artifacts: ${root}`);
    } else fs.rmSync(root, {recursive:true, force:true});
  }
}

test('Relay connections with the same request ID receive their own registration ACK', {timeout:20000}, async t => {
  await verifyRegistration(t);
});

test('Concurrent first Relay messages keep the hub and admin listener alive', {timeout:90000}, async t => {
  // Each fresh process starts with an empty json2 field metadata cache.
  for (let attempt = 0; attempt < 8; attempt++) {
    await t.test(`cold hub ${attempt + 1}`, async t => verifyRegistration(t, true));
  }
});
