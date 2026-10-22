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
async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('browser handoff: no URL secrets, single-use tickets, HttpOnly sessions, CSRF and restart revocation', {timeout: 60000}, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-browser-auth-'));
  const token = randomBytes(32).toString('hex');
  const webPort = await freePort();
  let adminPort;
  do { adminPort = await freePort(); } while (adminPort === webPort);
  const origin = `http://127.0.0.1:${adminPort}`;
  const config = path.join(root, 'vhttpd.toml');
  fs.writeFileSync(config, `[server]\nhost = "127.0.0.1"\nport = ${webPort}\n[files]\nevent_log = "${root}/events.ndjson"\npid_file = "${root}/runtime.pid"\n[worker]\nautostart = false\n[admin]\nenabled = true\nhost = "127.0.0.1"\nport = ${adminPort}\ntoken = "${token}"\non_data_plane = false\n`);
  let child, output = '', done;
  const request = async (route, options = {}) => {
    const response = await fetch(origin + route, {redirect: 'manual', signal: AbortSignal.timeout(3000), ...options});
    const body = await response.text();
    return {response, body};
  };
  async function start() {
    child = spawn(binary, ['--config', config], {cwd: repo, stdio: ['ignore', 'pipe', 'pipe']});
    child.stdout.on('data', d => { output += d; });
    child.stderr.on('data', d => { output += d; });
    done = new Promise(resolve => child.once('close', resolve));
    for (let i = 0; i < 180; i++) {
      assert.equal(child.exitCode, null, output);
      try { if ((await request('/health')).response.status === 200) return; } catch (_) {}
      await delay(100);
    }
    assert.fail('Admin listener did not become ready\n' + output);
  }
  async function stop() {
    if (!child || child.exitCode !== null) return;
    child.kill('SIGTERM');
    const timer = setTimeout(() => child.kill('SIGKILL'), 7000);
    await done;
    clearTimeout(timer);
  }
  const mint = async () => {
    const result = await request('/admin/auth/handoff', {method: 'POST', headers: {'x-vhttpd-admin-token': token}});
    assert.equal(result.response.status, 200, result.body);
    assert.equal(result.response.headers.get('cache-control'), 'no-store');
    const ticket = JSON.parse(result.body).ticket;
    assert.match(ticket, /^[a-f0-9]{64}$/);
    assert.notEqual(ticket, token);
    return ticket;
  };
  const exchange = ticket => request('/admin/auth/exchange', {method: 'POST', headers: {Origin: 'null', 'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({ticket})});
  try {
    await start();
    assert.equal((await request('/admin/runtime')).response.status, 403);
    assert.equal((await request('/admin/auth/handoff', {method: 'POST'})).response.status, 403);
    assert.equal((await request('/admin/auth/handoff', {method: 'POST', headers: {'x-vhttpd-admin-token': token, Origin: 'http://evil.test'}})).response.status, 403);
    const ticket = await mint();
    assert.equal((await request(`/admin/auth/exchange?ticket=${ticket}`, {method: 'POST'})).response.status, 403);
    const results = await Promise.all([exchange(ticket), exchange(ticket)]);
    assert.deepEqual(results.map(r => r.response.status).sort(), [303, 403]);
    const loggedIn = results.find(r => r.response.status === 303);
    assert.equal(loggedIn.response.headers.get('location'), '/admin/ui/');
    const setCookie = loggedIn.response.headers.get('set-cookie');
    assert.match(setCookie, /HttpOnly/i);
    assert.match(setCookie, /SameSite=Strict/i);
    assert.match(setCookie, /Path=\/admin/i);
    assert.doesNotMatch(setCookie, /Domain=/i);
    const cookie = setCookie.split(';')[0];
    assert.equal((await request('/admin/runtime', {headers: {Cookie: cookie}})).response.status, 200);
    assert.equal(JSON.parse((await request('/admin/auth/session', {headers: {Cookie: cookie}})).body).authenticated, true);
    assert.equal((await request('/admin/auth/logout', {method: 'POST', headers: {Cookie: cookie}})).response.status, 403);
    assert.equal((await request('/admin/auth/logout', {method: 'POST', headers: {Cookie: cookie, Origin: `http://127.0.0.1:${webPort}`, 'Sec-Fetch-Site': 'same-site'}})).response.status, 403);
    assert.equal((await request('/admin/runtime', {headers: {Cookie: cookie, 'Sec-Fetch-Site': 'cross-site'}})).response.status, 403);
    assert.equal((await request('/admin/auth/logout', {method: 'POST', headers: {Cookie: cookie, Origin: origin}})).response.status, 200);
    assert.equal((await request('/admin/runtime', {headers: {Cookie: cookie}})).response.status, 403);
    const secondTicket = await mint();
    const secondLogin = await exchange(secondTicket);
    const secondCookie = secondLogin.response.headers.get('set-cookie').split(';')[0];
    await stop();
    await start();
    assert.equal((await request('/admin/runtime', {headers: {Cookie: secondCookie}})).response.status, 403);
    assert.equal((await exchange(secondTicket)).response.status, 403);
    assert.equal(output.includes(token), false, 'Admin token leaked to logs');
    assert.equal(output.includes(secondTicket), false, 'Ticket leaked to logs');
    const ui = await request('/admin/ui/');
    assert.equal(ui.response.status, 200);
  } finally {
    await stop();
    fs.rmSync(root, {recursive: true, force: true});
  }
});
