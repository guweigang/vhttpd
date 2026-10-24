import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import '../../admin/ui/relay-config.js';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
async function until(fn) {
  let last;
  for (let i = 0; i < 120; i++) {
    try { const result = await fn(); if (result) return result; } catch (e) { last = e; }
    await pause(100);
  }
  throw new Error('Timed out: ' + (last?.message || 'condition not met'));
}

test('cross-include Relay, Pipeline and Adapter changes publish together and serve real traffic', {timeout:60000}, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-cross-include-'));
  const allocated = new Set();
  async function port() {
    let value;
    do { value = await freePort(); } while (allocated.has(value));
    allocated.add(value);
    return value;
  }
  const hubPort = await port(), webPort = await port(), hubAdmin = await port();
  const agentWeb = await port(), agentAdmin = await port();
  const token = 'cross-include-local-test';
  const children = [];
  const logs = new Map();
  const requests = [];
  function traceRequest(admin, route, method = 'GET') {
    requests.push({at:Date.now(), port:admin, method, route});
    if (requests.length > 256) requests.shift();
  }
  let failed = false;
  function fixture(name, web, admin, hub) {
    const dir = path.join(root, name);
    fs.mkdirSync(path.join(dir, 'config'), {recursive:true});
    const entry = path.join(dir, 'vhttpd.toml');
    const relay = path.join(dir, 'config', 'relay.toml');
    const routes = path.join(dir, 'config', 'routes.toml');
    const adapters = path.join(dir, 'config', 'adapters.toml');
    const pipeline = hub ? 'public/relay' : 'relay/response';
    fs.writeFileSync(entry, `version=2
include=["config/relay.toml","config/routes.toml","config/adapters.toml"]
[server]
pid_file="${dir}/runtime.pid"
[observability]
event_log="${dir}/events.ndjson"
[listeners.web]
protocol="http"
transport="tcp"
host="127.0.0.1"
port=${web}
[listeners.admin]
protocol="http"
transport="tcp"
host="127.0.0.1"
port=${admin}
[control]
listener="listener:admin"
token="${token}"
${hub ? `[listeners.relay]\nprotocol="websocket"\ntransport="tcp"\nhost="127.0.0.1"\nport=${hubPort}\n` : ''}
[[pipelines]]
id="health"
ingress="listener:web"
match.paths=["/health"]
egress="adapter:reply"
`);
    fs.writeFileSync(relay, `[relays.edge]
mode="${hub ? 'hub' : 'agent'}"
carrier="websocket"
${hub ? 'listener="listener:relay"\npath="/vhttpd/relay"' : `url="ws://127.0.0.1:${hubPort}/vhttpd/relay"\nautostart=true`}
node_id="${name}-before"
token="pair-test"
`);
    fs.writeFileSync(routes, `# Preserve routing and source ownership.
[[pipelines]]
id="${pipeline}"
ingress="listener:web"
match.paths=["/relay"]
egress="adapter:reply"
`);
    const managed = 'relay-ui-edge-' + Buffer.from(pipeline).toString('hex');
    fs.writeFileSync(adapters, `[adapters.reply]
kind="fixed-response"
options.status="200"
options.body="${hub ? 'before' : 'cross include response'}"
${hub ? `[adapters.${managed}]\nkind="relay-delivery"\noptions.target="relay:edge"\noptions.route="old-route"\n` : ''}`);
    return {entry, relay, routes, adapters, pipeline, original:fs.readFileSync(entry, 'utf8')};
  }
  const hub = fixture('hub', webPort, hubAdmin, true);
  const agent = fixture('agent', agentWeb, agentAdmin, false);
  async function request(admin, route, options = {}, expected = 200) {
    let response;
    traceRequest(admin, route, options.method || 'GET');
    try {
      response = await fetch(`http://127.0.0.1:${admin}${route}`, {
        signal:AbortSignal.timeout(3000), ...options,
        headers:{'x-vhttpd-admin-token':token, ...options.headers}
      });
    } catch (cause) {
      throw new Error(`${options.method || 'GET'} ${admin}${route}: ${cause.message} (${cause.cause?.code || cause.name})`, {cause});
    }
    const body = await response.json();
    assert.equal(response.status, expected, JSON.stringify(body));
    return body;
  }
  async function start(config, admin) {
    const child = spawn(binary, ['--config', config], {cwd:repo, stdio:['ignore','pipe','pipe']});
    let log = '';
    child.stdout.on('data', data => log = (log + data).slice(-100000));
    child.stderr.on('data', data => log = (log + data).slice(-100000));
    children.push(child);
    const record = {config, text:() => log, error:null, closed:new Promise(resolve => child.once('close', resolve))};
    child.once('error', error => record.error = error.message);
    logs.set(child, record);
    try { await until(async () => {
      if (record.error) throw new Error(record.error);
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`server exited: ${child.exitCode}/${child.signalCode}\n${log}`);
      return !!(await request(admin, '/admin/runtime'));
    }); } catch (e) { throw new Error(e.message + '\n' + log); }
    return child;
  }
  async function stop(child) {
    const record = logs.get(child);
    if (record.error || child.exitCode !== null || child.signalCode !== null) {
      await record.closed;
      return;
    }
    const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
    try {
      child.kill('SIGTERM');
      await record.closed;
    } finally { clearTimeout(timer); }
  }
  const base = {id:'edge', carrier:'websocket', token:'pair-test', max_channels:1024, channel_buffer:64, reconnect_delay_ms:100};
  async function save(admin, id, workspace, edit) {
    return request(admin, '/admin/config/changesets?id=' + id, {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({config_path:workspace.config_path, files:edit.changes})});
  }
  try {
    let hubChild = await start(hub.entry, hubAdmin);
    let agentChild = await start(agent.entry, agentAdmin);
    traceRequest(hubAdmin, '/admin/config/workspace (anonymous)');
    const anonymous = await fetch(`http://127.0.0.1:${hubAdmin}/admin/config/workspace`);
    assert.equal(anonymous.status, 403);
    const hw = await request(hubAdmin, '/admin/config/workspace');
    const aw = await request(agentAdmin, '/admin/config/workspace');
    assert.equal(hw.pipelines.find(p => p.id === hub.pipeline).source_path, hub.routes);
    const he = RelayConfig.projectEdit(hw, hub.relay, {...base, mode:'hub', node_id:'hub-after', listener:'listener:relay', path:'/vhttpd/relay'}, {pipeline:hub.pipeline, direction:'outgoing', route:agent.pipeline});
    const ae = RelayConfig.projectEdit(aw, agent.relay, {...base, mode:'agent', node_id:'agent-after', url:`ws://127.0.0.1:${hubPort}/vhttpd/relay`, autostart:true}, {pipeline:agent.pipeline, direction:'incoming', egress:'adapter:reply'});
    assert.deepEqual(new Set(he.changes.map(f => f.path)), new Set([hub.relay, hub.routes, hub.adapters]));
    assert.deepEqual(new Set(ae.changes.map(f => f.path)), new Set([agent.relay, agent.routes]));
    const invalid = {changes:ae.changes.map(f => ({...f, value:f.path === agent.routes ? f.value.replace('adapter:reply','adapter:missing') : f.value}))};
    await save(agentAdmin, 'invalid', aw, invalid);
    assert.equal((await request(agentAdmin, '/admin/config/changesets/invalid/validate', {method:'POST'}, 422)).ok, false);
    await request(agentAdmin, '/admin/config/changesets/invalid/publish', {method:'POST'}, 422);
    for (const file of ae.changes) assert.equal(fs.readFileSync(file.path, 'utf8'), file.original);
    await save(agentAdmin, 'conflict', aw, ae);
    const originalRoutes = fs.readFileSync(agent.routes, 'utf8');
    fs.writeFileSync(agent.routes, originalRoutes + '\n# external edit\n');
    await request(agentAdmin, '/admin/config/changesets/conflict/publish', {method:'POST'}, 422);
    assert.equal(fs.readFileSync(agent.relay, 'utf8'), ae.changes.find(f => f.path === agent.relay).original);
    assert(fs.readFileSync(agent.routes, 'utf8').includes('# external edit'));
    fs.writeFileSync(agent.routes, originalRoutes);
    for (const [admin, workspace, edit] of [[hubAdmin, hw, he], [agentAdmin, aw, ae]]) {
      await save(admin, 'publish', workspace, edit);
      assert.equal((await request(admin, '/admin/config/changesets/publish/validate', {method:'POST'})).ok, true);
      assert.equal((await request(admin, '/admin/config/changesets/publish/diff')).strategy, 'relay_reload_required');
      const published = await request(admin, '/admin/config/changesets/publish/publish', {method:'POST'});
      assert.deepEqual(new Set(published.paths), new Set(edit.changes.map(f => f.path)));
      for (const file of edit.changes) assert.equal(fs.readFileSync(file.path, 'utf8'), file.value);
    }
    assert.equal(fs.readFileSync(hub.entry, 'utf8'), hub.original);
    assert.equal(fs.readFileSync(agent.entry, 'utf8'), agent.original);
    await stop(hubChild); await stop(agentChild);
    hubChild = await start(hub.entry, hubAdmin);
    agentChild = await start(agent.entry, agentAdmin);
    await until(async () => (await request(agentAdmin, '/admin/runtime')).relay.agents.some(a => a.node_id === 'agent-after' && a.state === 'registered'));
    await until(async () => {
      const response = await fetch(`http://127.0.0.1:${webPort}/relay`, {signal:AbortSignal.timeout(3000)});
      return response.status === 200 && await response.text() === 'cross include response';
    });
    for (const [admin, fixture] of [[hubAdmin, hub], [agentAdmin, agent]]) {
      const preview = await request(admin, '/admin/runtime/plan/replacement?config=' + encodeURIComponent(fixture.entry));
      assert.equal(preview.allowed, true);
      assert.deepEqual(preview.actions, []);
    }
  } catch (error) {
    failed = true;
    throw error;
  } finally {
    await Promise.all(children.map(stop));
    if (failed || process.env.VHTTPD_E2E_KEEP_TMP === '1') {
      const processes = children.map((child, index) => {
        const record = logs.get(child);
        const file = `server-${child.pid ?? `spawn-${index}`}.log`;
        fs.writeFileSync(path.join(root, file), record.text());
        return {pid:child.pid, config:record.config, exitCode:child.exitCode, signalCode:child.signalCode, error:record.error, log:file};
      });
      fs.writeFileSync(path.join(root, 'processes.json'), JSON.stringify(processes, null, 2));
      fs.writeFileSync(path.join(root, 'requests.json'), JSON.stringify(requests, null, 2));
      t.diagnostic(`Cross-include fixture and process logs: ${root}`);
    } else fs.rmSync(root, {recursive:true, force:true});
  }
});
