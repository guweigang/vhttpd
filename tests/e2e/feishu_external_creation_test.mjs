import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function port() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const result = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return result;
}
async function php(source, env) {
  const child = spawn('php', ['-r', source], {cwd: repo, env: {...process.env, ...env}});
  let stdout = '', stderr = '';
  child.stdout.on('data', d => { stdout += d; });
  child.stderr.on('data', d => { stderr += d; });
  const code = await new Promise(resolve => child.once('close', resolve));
  assert.equal(code, 0, stderr);
  return JSON.parse(stdout);
}

test('external PHP issuance: captured grants, expiry, 4096 capacity, revoke/replay and restart', {timeout: 120000}, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-external-creation-'));
  const token = randomBytes(32).toString('hex');
  const webPort = await port();
  let adminPort;
  do { adminPort = await port(); } while (adminPort === webPort);
  const origin = `http://127.0.0.1:${adminPort}`;
  const route = '/admin/runtime/feishu/creation';
  const config = path.join(root, 'vhttpd.toml');
  const writeConfig = value => fs.writeFileSync(config, `[server]\nhost = "127.0.0.1"\nport = ${webPort}\n[files]\nevent_log = "${root}/events.ndjson"\npid_file = "${root}/runtime.pid"\n[worker]\nautostart = false\n[admin]\nenabled = true\nhost = "127.0.0.1"\nport = ${adminPort}\ntoken = "${value}"\non_data_plane = false\n`);
  let child, done, output = '';
  const secrets = [token];
  const request = async (suffix = '', options = {}) => {
    const response = await fetch(origin + route + suffix, {redirect: 'manual', signal: AbortSignal.timeout(3000), ...options});
    return {status: response.status, headers: response.headers, body: await response.text()};
  };
  const post = (body, suffix = '') => request(suffix, {method: 'POST', headers: {'x-vhttpd-admin-token': token, 'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  async function start() {
    child = spawn(binary, ['--config', config], {cwd: repo, stdio: ['ignore', 'pipe', 'pipe']});
    child.stdout.on('data', d => { output += d; });
    child.stderr.on('data', d => { output += d; });
    done = new Promise(resolve => child.once('close', resolve));
    for (let i = 0; i < 180; i++) {
      assert.equal(child.exitCode, null, output);
      try { if ((await fetch(origin + '/health')).status === 200) return; } catch {}
      await delay(100);
    }
    assert.fail('Listener did not become ready\n' + output);
  }
  async function stop() {
    if (!child || child.exitCode !== null) return;
    child.kill('SIGTERM');
    const timer = setTimeout(() => child.kill('SIGKILL'), 7000);
    await done;
    clearTimeout(timer);
  }
  try {
    writeConfig(token);
    await start();
    assert.equal((await request()).status, 403);
    assert.equal((await request(`?token=${token}`)).status, 403);
    assert.equal((await request('', {method: 'POST', body: '{}'})).status, 403);
    assert.notEqual((await fetch(`http://127.0.0.1:${webPort}${route}`, {headers: {'x-vhttpd-admin-token': token}})).status, 200);
    const handoff = await fetch(origin + '/admin/auth/handoff', {method: 'POST', headers: {'x-vhttpd-admin-token': token}});
    assert.equal(handoff.status, 200);
    const ticket = (await handoff.json()).ticket;
    const login = await fetch(origin + '/admin/auth/exchange', {method: 'POST', redirect: 'manual', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({ticket})});
    assert.equal(login.status, 303);
    const cookie = login.headers.get('set-cookie').split(';')[0];
    assert.equal((await request('', {headers: {Cookie: cookie}})).status, 403, 'browser sessions cannot mint worker authority');
    assert.equal((await request('', {method: 'POST', headers: {'x-vhttpd-admin-token': token}, body: '{'})).status, 400);
    assert.equal((await request('', {method: 'POST', headers: {'x-vhttpd-admin-token': token}, body: 'x'.repeat(8193)})).status, 400);
    const discovered = await request('', {headers: {'x-vhttpd-admin-token': token}});
    assert.equal(discovered.status, 200, discovered.body);
    assert.equal(discovered.headers.get('cache-control'), 'no-store');
    const discovery = JSON.parse(discovered.body);
    const invalid = {epoch: discovery.epoch, issued_at: discovery.issued_at, request_id: 'a'.repeat(64), stream_id: 'stream', instance: 'main', kind: 'send', message_id: ''};
    assert.equal((await post({...invalid, epoch: 'old'})).status, 409);
    assert.equal((await post({...invalid, issued_at: discovery.issued_at - 301})).status, 409);
    assert.equal((await post({...invalid, kind: 'bind'})).status, 409);
    const script = `require 'php/package/src/VHttpd/Feishu/CreationLease.php'; require 'php/package/src/VHttpd/Feishu/CreationClient.php'; $client = VHttpd\\Feishu\\CreationClient::fromEnvironment(); $lease = $client->issue('php-stream', 'main', getenv('BIND_TARGET') ?: ''); $command = $lease->command(['type' => getenv('BIND_TARGET') ? 'session.bind' : 'provider.message.send', 'provider' => 'feishu', 'stream_id' => 'php-stream', 'target_type' => getenv('BIND_TARGET') ? 'message_id' : 'chat_id', 'target' => getenv('BIND_TARGET') ?: 'chat']); echo json_encode(['request' => $lease->request, 'generation' => $lease->generation, 'token' => $lease->token, 'command' => $command], JSON_THROW_ON_ERROR);`;
    const env = {VHTTPD_ADMIN_BASE_URL: origin, VHTTPD_ADMIN_TOKEN: token};
    for (const target of ['', 'physical-message']) {
      const issued = await php(script, {...env, BIND_TARGET: target});
      secrets.push(issued.token);
      assert.match(issued.token, /^[a-f0-9]{64}$/);
      assert.equal(issued.command.metadata.creation_token, issued.token);
      assert.equal(issued.command.metadata[target ? 'creation_generation' : 'stream_generation'], issued.generation);
      const replays = await Promise.all([post(issued.request), post(issued.request)]);
      for (const replay of replays) {
        assert.equal(replay.status, 200, replay.body);
        assert.deepEqual(JSON.parse(replay.body), {generation: issued.generation, token: issued.token});
      }
      assert.equal((await post({...issued.request, stream_id: 'other'})).status, 409);
      assert.equal((await post(issued.request, '/revoke')).status, 200);
      assert.equal((await post(issued.request, '/revoke')).status, 200);
      assert.equal((await post(issued.request)).status, 409);
    }
    const reordered = {...invalid, request_id: 'b'.repeat(64)};
    assert.equal((await post(reordered, '/revoke')).status, 200);
    assert.equal((await post(reordered)).status, 409);
    const first = await post(invalid);
    assert.equal(first.status, 200, first.body);
    assert.equal(first.headers.get('cache-control'), 'no-store');
    await stop();
    await start();
    assert.equal((await post(invalid)).status, 409, 'previous-process intent must not mint on restart');
    // Use server discovery time to exercise real expiry without changing the
    // process clock or adding a shorter production credential lifetime.
    const near = JSON.parse((await request('', {headers: {'x-vhttpd-admin-token': token}})).body);
    const expiring = {...invalid, epoch: near.epoch, issued_at: near.issued_at - 298, request_id: 'c'.repeat(64), stream_id: 'abandoned-on-interrupt'};
    const expiringReply = await post(expiring);
    assert.equal(expiringReply.status, 200, expiringReply.body);
    const expiringLease = JSON.parse(expiringReply.body);
    secrets.push(expiringLease.token);
    const expiryDeadline = Date.now() + 5000;
    while (true) {
      const current = JSON.parse((await request('', {headers: {'x-vhttpd-admin-token': token}})).body);
      if (current.issued_at >= expiring.issued_at + 300) break;
      assert.ok(Date.now() < expiryDeadline, 'server expiry clock did not advance');
      await delay(50);
    }
    assert.equal((await post(expiring)).status, 409, 'expired intent was renewed');
    assert.equal((await post(expiring, '/revoke')).status, 409, 'expired revoke was treated as live authority');
    const afterExpiry = JSON.parse((await request('', {headers: {'x-vhttpd-admin-token': token}})).body);
    assert.equal((await post({...expiring, issued_at: afterExpiry.issued_at, request_id: 'd'.repeat(64), stream_id: 'fresh-after-expiry'})).status, 200);

    // Start a clean process so the exact production capacity can be exercised.
    await stop();
    await start();
    const capacityDiscovery = JSON.parse((await request('', {headers: {'x-vhttpd-admin-token': token}})).body);
    const intents = Array.from({length: 4096}, (_, i) => ({...invalid, epoch: capacityDiscovery.epoch, issued_at: capacityDiscovery.issued_at, request_id: i.toString(16).padStart(64, '0'), stream_id: 'unconsumed-' + i}));
    let retained;
    for (let offset = 0; offset < intents.length; offset += 32) {
      const results = await Promise.all(intents.slice(offset, offset + 32).map(body => post(body)));
      for (const result of results) assert.equal(result.status, 200, result.body);
      if (offset === 0) retained = JSON.parse(results[0].body);
    }
    secrets.push(retained.token);
    const overflow = {...intents[0], request_id: 'e'.repeat(64), stream_id: 'overflow'};
    assert.equal((await post(overflow)).status, 409, 'capacity did not fail closed');
    assert.deepEqual(JSON.parse((await post(intents[0])).body), retained, 'capacity evicted live replay evidence');
    for (const intent of intents.slice(0, 8)) assert.equal((await post(intent, '/revoke')).status, 200);
    assert.equal((await post(intents[0])).status, 409, 'revoked intent was refreshed at capacity');
    assert.equal((await post(overflow)).status, 409, 'unexpired memo evidence was evicted after grant release');
    await stop();
    await start();
    assert.equal((await post(intents[0])).status, 409, 'previous-process capacity intent became live');
    const restarted = JSON.parse((await request('', {headers: {'x-vhttpd-admin-token': token}})).body);
    assert.notEqual(restarted.epoch, capacityDiscovery.epoch);
    assert.equal((await post({...overflow, epoch: restarted.epoch, issued_at: restarted.issued_at})).status, 200, 'new process retained old capacity');
    await stop();
    writeConfig('');
    await start();
    assert.equal((await request()).status, 403, 'open-admin mode must not grant issuance');
    assert.equal((await request('', {headers: {'x-vhttpd-admin-token': token}})).status, 403);
    const events = fs.existsSync(path.join(root, 'events.ndjson')) ? fs.readFileSync(path.join(root, 'events.ndjson'), 'utf8') : '';
    for (const secret of secrets) {
      assert.equal(output.includes(secret), false, 'credential leaked to terminal logs');
      assert.equal(events.includes(secret), false, 'credential leaked to event log');
    }
  } finally {
    await stop();
    fs.rmSync(root, {recursive: true, force: true});
  }
});
