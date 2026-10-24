// Disposable simulator backend: loopback HTTP + real vhttpd/vjsx + PostgreSQL.
// No real credentials, no existing DB, and no real WeChat identity validation.
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';

const example = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const binary = process.env.VHTTPD_BIN;
if (!binary || !existsSync(binary)) throw Error('Set VHTTPD_BIN to a DB-enabled vhttpd binary');
const port = Number(process.env.WCF_LOCAL_PORT || 19886);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw Error('Invalid WCF_LOCAL_PORT');
const bootstrapMs = Number(process.env.VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS || 120000);
if (!Number.isInteger(bootstrapMs) || bootstrapMs < 1 || bootstrapMs > 300000) {
  throw Error('VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS must be 1..300000');
}
const availablePort = port => new Promise((resolve, reject) => {
  const server = createServer();
  server.on('error', reject);
  server.listen(port, '127.0.0.1', () => {
    const result = server.address().port;
    server.close(() => resolve(result));
  });
});
await availablePort(port); // Fail before creating a database if HTTP port is busy.
const dbPort = await availablePort(0);
const root = await mkdtemp(join(tmpdir(), 'wcf-local-'));
const pgRoot = '/Applications/Postgres.app/Contents/Versions/latest/bin/';
function program(name, env) {
  if (process.env[env]) return process.env[env];
  try { return execFileSync('which', [name], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']}).trim(); }
  catch (_) {
    if (existsSync(pgRoot + name)) return pgRoot + name;
    throw Error('Missing PostgreSQL tool: ' + name);
  }
}
function run(command, args, input = '') {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {stdio: ['pipe', 'pipe', 'pipe']});
    let output = '', errors = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { errors += data; });
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve(output.trim()) : reject(Error(command + ': ' + errors)));
    child.stdin.end(input);
  });
}
let pgCtl, pgStarted = false, server;
let stopRequested;
const stopped = new Promise(resolve => { stopRequested = resolve; });
process.once('SIGINT', stopRequested);
process.once('SIGTERM', stopRequested);
try {
  const initdb = program('initdb', 'WCF_INITDB');
  const psql = program('psql', 'WCF_PSQL');
  pgCtl = program('pg_ctl', 'WCF_PG_CTL');
  const directory = join(root, 'postgres');
  console.log('Initializing disposable PostgreSQL: ' + root);
  await run(initdb, ['-D', directory, '-U', 'wcf_local', '-A', 'trust', '--encoding=UTF8', '--no-locale']);
  await run(pgCtl, ['-D', directory, '-l', join(root, 'postgres.log'), '-o',
    '-h 127.0.0.1 -p ' + dbPort + ' -k ' + root, 'start']);
  pgStarted = true;
  console.log('PostgreSQL ready; starting vhttpd on 127.0.0.1:' + port);
  const sql = statement => run(psql, ['-h', '127.0.0.1', '-p', String(dbPort), '-U', 'wcf_local',
    '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At'], statement);
  await sql(await readFile(join(example, 'schema.sql'), 'utf8'));
  const config = join(root, 'vhttpd.toml');
  await writeFile(config, `version = 2
[server]
pid_file = "${root}/vhttpd.pid"
[observability]
event_log = "${root}/events.ndjson"
[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${port}
[resources.db.wechat]
kind = "pgsql"
host = "127.0.0.1"
port = ${dbPort}
username = "wcf_local"
password = ""
database = "postgres"
pool_size = 4
options = {socket = "${root}/db.sock", pool_name = "wechat"}
[engines.wechat]
kind = "vjsx"
entry = "${example}/tests/local-entry.mjs"
module_root = "${example}"
runtime_profile = "node"
thread_count = 1
enable_network = true
resources = ["resource:db/wechat"]
[adapters.wechat]
kind = "http-handler"
engine = "engine:wechat"
[[pipelines]]
id = "wechat"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:wechat"
`);
  server = spawn(binary, ['--config', config], {cwd: resolve(example, '../..'),
    env: {...process.env, WECHAT_APP_ID: 'local-demo', WECHAT_APP_SECRET: 'local-only-not-a-secret',
      WECHAT_DB_DRIVER: 'pgsql', WECHAT_FUNCTION_TIMEOUT_MS: '3000',
      VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS: String(bootstrapMs),
      VHTTPD_LOG_LEVEL: process.env.VHTTPD_LOG_LEVEL || 'error'}, stdio: ['ignore', 'pipe', 'pipe']});
  let serverError;
  server.on('error', error => { serverError = error; stopRequested(); });
  server.once('exit', stopRequested);
  server.stdout.on('data', data => process.stdout.write(data));
  server.stderr.on('data', data => process.stderr.write(data));
  const base = 'http://127.0.0.1:' + port;
  let ready = false;
  // Default and named engine warmups are sequential. Allow both cold starts,
  // without changing function / transaction timeouts or treating 502 as ready.
  const readyUntil = Date.now() + 2 * bootstrapMs + 15000;
  let lastError;
  while (Date.now() < readyUntil) {
    if (serverError) throw serverError;
    if (server.exitCode !== null || server.signalCode !== null) throw Error('vhttpd exited');
    try {
      // A listening HTTP socket (or a 502) does not prove a usable JS lane.
      // Probe the complete login + SQL path without printing its token.
      const response = await fetch(base + '/auth/login', {method: 'POST',
        headers: {'content-type': 'application/json'}, body: JSON.stringify({code: 'local-readiness-probe'}),
        signal: AbortSignal.timeout(5000)});
      if (response.status !== 200) throw Error('login probe HTTP ' + response.status);
      const session = await response.json();
      const user = await fetch(base + '/functions/getUser', {method: 'POST', body: '{}',
        headers: {'content-type': 'application/json', authorization: 'Bearer ' + session.token},
        signal: AbortSignal.timeout(5000)});
      if (user.status !== 200 || (await user.json()).result?.openid !== 'local-demo-user') {
        throw Error('user SQL probe failed');
      }
      ready = true; break;
    } catch (error) { lastError = error; await new Promise(resolve => setTimeout(resolve, 500)); }
  }
  if (!ready) throw Error('vhttpd startup timed out: ' + lastError?.message);
  console.log('\nLOCAL DEMO READY: ' + base + '\nFAKE IDENTITY ONLY: local-demo-user (not a verified WeChat user)');
  console.log('Temporary PostgreSQL: ' + root + '\nCtrl-C stops both servers and removes only this temporary directory.');
  console.log('Stop from another terminal: kill -TERM ' + process.pid);
  await stopped;
  if (serverError) throw serverError;
} finally {
  if (server && server.exitCode === null && server.signalCode === null) {
    const exit = new Promise(resolve => server.once('exit', resolve));
    server.kill('SIGTERM');
    const timer = setTimeout(() => server.kill('SIGKILL'), 5000);
    await exit; clearTimeout(timer);
  }
  if (pgStarted) await run(pgCtl, ['-D', join(root, 'postgres'), '-m', 'fast', 'stop']);
  await rm(root, {recursive: true, force: true});
  console.log('Local demo stopped; temporary database removed.');
}
