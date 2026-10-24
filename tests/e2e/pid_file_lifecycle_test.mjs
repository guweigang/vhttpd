import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function listener() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return server;
}
async function freePort() {
  const server = await listener();
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
function start(root, label, port, pidFile) {
  const config = path.join(root, `${label}.toml`);
  fs.writeFileSync(config, `[server]\nhost = "127.0.0.1"\nport = ${port}\n[files]\nevent_log = "${root}/${label}.ndjson"\npid_file = "${pidFile}"\n[worker]\nautostart = false\n[admin]\nenabled = false\n`);
  const child = spawn(binary, ['--config', config], {cwd: repo, stdio: ['ignore', 'pipe', 'pipe']});
  const state = {child, output: '', exited: false, code: null, signal: null};
  child.stdout.on('data', data => { state.output += data; });
  child.stderr.on('data', data => { state.output += data; });
  state.done = new Promise(resolve => {
    child.once('error', err => {
      state.output += String(err); Object.assign(state, {exited: true, code: -1}); resolve();
    });
    child.once('close', (code, signal) => {
      Object.assign(state, {exited: true, code, signal}); resolve();
    });
  });
  return state;
}
async function until(check, state, message) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (await check()) return;
    await delay(10);
  }
  assert.fail(`${message}\n${state.output}`);
}
async function ready(state, port) {
  await until(async () => {
    assert.equal(state.exited, false, state.output);
    try { const res = await fetch(`http://127.0.0.1:${port}/`, {signal: AbortSignal.timeout(300)}); await res.arrayBuffer(); return true; }
    catch { return false; }
  }, state, 'server did not become ready');
}
async function stopped(state) {
  await until(() => state.exited, state, 'process did not exit');
}
async function dispose(state) {
  if (!state || state.exited) return;
  state.child.kill('SIGTERM');
  try { await stopped(state); }
  finally { if (!state.exited) { state.child.kill('SIGKILL'); await state.done; } }
}

for (const signal of ['SIGTERM', 'SIGINT']) {
  test(`${signal} releases the process-owned PID file`, async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-pid-e2e-'));
    const pidFile = path.join(root, 'server.pid');
    let state;
    try {
      const port = await freePort(); state = start(root, 'server', port, pidFile);
      await ready(state, port);
      assert.equal(fs.readFileSync(pidFile, 'utf8'), String(state.child.pid));
      state.child.kill(signal); await stopped(state);
      assert.equal(state.code, signal === 'SIGTERM' ? 143 : 130, state.output);
      assert.equal(fs.existsSync(pidFile), false);
    } finally { await dispose(state); fs.rmSync(root, {recursive: true, force: true}); }
  });
}

test('another process cannot overwrite an active PID file or unlink it on failure', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-pid-e2e-'));
  const pidFile = path.join(root, 'shared.pid');
  let first, second;
  try {
    const port = await freePort(); first = start(root, 'first', port, pidFile); await ready(first, port);
    second = start(root, 'second', await freePort(), pidFile); await stopped(second);
    assert.notEqual(second.code, 0, second.output);
    assert.match(second.output, /cannot acquire PID file/);
    assert.equal(fs.readFileSync(pidFile, 'utf8'), String(first.child.pid));
    await ready(first, port);
  } finally { await dispose(second); await dispose(first); fs.rmSync(root, {recursive: true, force: true}); }
});

test('bind preflight failure neither publishes nor overwrites a PID file', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-pid-e2e-'));
  const pidFile = path.join(root, 'server.pid');
  const blocked = await listener();
  let state;
  try {
    for (const existing of [false, true]) {
      if (existing) fs.writeFileSync(pidFile, 'keep');
      state = start(root, `blocked-${existing}`, blocked.address().port, pidFile); await stopped(state);
      assert.notEqual(state.code, 0, state.output);
      assert.match(state.output, /bind preflight failed/);
      if (existing) assert.equal(fs.readFileSync(pidFile, 'utf8'), 'keep');
      else assert.equal(fs.existsSync(pidFile), false);
    }
  } finally { await dispose(state); await new Promise(resolve => blocked.close(resolve)); fs.rmSync(root, {recursive: true, force: true}); }
});

test('signal cleanup preserves a replacement inode containing the same PID', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-pid-e2e-'));
  const pidFile = path.join(root, 'server.pid');
  let state;
  try {
    const port = await freePort(); state = start(root, 'server', port, pidFile); await ready(state, port);
    const text = fs.readFileSync(pidFile, 'utf8');
    fs.unlinkSync(pidFile); fs.writeFileSync(pidFile, text);
    state.child.kill('SIGTERM'); await stopped(state);
    assert.equal(state.code, 143, state.output);
    assert.equal(fs.readFileSync(pidFile, 'utf8'), text);
  } finally { await dispose(state); fs.rmSync(root, {recursive: true, force: true}); }
});
