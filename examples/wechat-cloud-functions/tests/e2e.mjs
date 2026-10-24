// Disposable local integration test. Never accepts an existing database URL.
import assert from "node:assert/strict";
import {spawn, execFileSync} from "node:child_process";
import {mkdtemp, writeFile, readFile, rm} from "node:fs/promises";
import {existsSync} from "node:fs";
import {tmpdir} from "node:os";
import {join, resolve, dirname} from "node:path";
import {fileURLToPath} from "node:url";
import {createServer, request as httpRequest} from "node:http";
import {createServer as createNetServer} from "node:net";

const example = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repository = resolve(example, "../..");
const binary = process.env.VHTTPD_BIN;
if (!binary || !existsSync(binary)) throw Error("Set VHTTPD_BIN to an existing DB-enabled vhttpd binary");
const root = await mkdtemp(join(tmpdir(), "wcf-e2e-"));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const logs = [];
const freePort = () => new Promise((resolve, reject) => {
  const listener = createNetServer();
  listener.on("error", reject);
  listener.listen(0, "127.0.0.1", () => { const port = listener.address().port; listener.close(() => resolve(port)); });
});

function program(variable, candidates) {
  if (process.env[variable]) return process.env[variable];
  for (const candidate of candidates) {
    if (candidate.includes("/") && existsSync(candidate)) return candidate;
    try { return execFileSync("which", [candidate], {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]}).trim(); } catch (_) {}
  }
  throw Error("Missing test dependency: " + variable);
}

function run(command, args, input = "", timeout = 60000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {stdio: ["pipe", "pipe", "pipe"]});
    let output = "", errors = "";
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(Error("command timed out: " + command)); }, timeout);
    child.on("error", error => { clearTimeout(timer); reject(error); });
    child.stdout.on("data", data => { output += data; });
    child.stderr.on("data", data => { errors += data; });
    child.on("exit", code => {
      clearTimeout(timer);
      if (code === 0) resolve(output.trim()); else reject(Error(command + " exited " + code + ": " + errors));
    });
    child.stdin.end(input);
  });
}

function background(command, args, env = process.env) {
  const child = spawn(command, args, {cwd: repository, env, stdio: ["ignore", "pipe", "pipe"]});
  child.on("error", error => logs.push(error.message));
  for (const stream of [child.stdout, child.stderr]) stream.on("data", data => {
    logs.push(String(data));
    if (logs.length > 1000) logs.shift();
  });
  return child;
}

async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise(resolve => child.once("exit", resolve));
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 8000);
  await exited;
  clearTimeout(timer);
}

async function waitReady(check, child) {
  const end = Date.now() + 30000;
  let last;
  while (Date.now() < end) {
    if (child && (child.exitCode !== null || child.signalCode !== null)) throw Error("test server exited early");
    try { await check(); return; } catch (error) { last = error; }
    await pause(100);
  }
  throw last || Error("server not ready");
}

const pgRoot = "/Applications/Postgres.app/Contents/Versions/latest/bin/";
let mysqlServer, vhttpd, pgDirectory, pgCtl;
let mysqlAdmin, mysqlSocket;
const usedCodes = new Set();
let peerFailure;
const peer = createServer((req, res) => {
  try {
  const url = new URL(req.url, "http://fixture");
  const code = url.searchParams.get("js_code");
  assert.equal(url.pathname, "/sns/jscode2session");
  assert.equal(url.searchParams.get("appid"), "test-app");
  assert.equal(url.searchParams.get("secret"), "fixture-secret");
  assert.equal(url.searchParams.get("grant_type"), "authorization_code");
  let value;
  if (!/^(alice|bob)-[0-9]+$/.test(code || "") || usedCodes.has(code)) value = {errcode: 40029, errmsg: "bad or consumed code"};
  else {
    usedCodes.add(code);
    value = {openid: code.split("-")[0], session_key: "SECRET_SESSION_KEY", unionid: "union-" + code.split("-")[0]};
  }
  res.writeHead(200, {"content-type": "application/json"});
  res.end(JSON.stringify(value));
  } catch (error) {
    // Keep failures in the awaited test flow so finally can stop its children.
    peerFailure = error;
    res.writeHead(500);
    res.end('{}');
  }
});
await new Promise(resolve => peer.listen(0, "127.0.0.1", resolve));
const peerUrl = "http://127.0.0.1:" + peer.address().port;
let sequence = 0;

try {
  const drivers = process.argv.includes("--mysql-only") ? ["mysql"] : process.argv.includes("--pgsql-only") ? ["pgsql"] : ["mysql", "pgsql"];
  for (const driver of drivers) {
    const dbPort = await freePort(), httpPort = await freePort();
    let sql;
    if (driver === "mysql") {
      const mysqld = program("WCF_MYSQLD", ["mysqld", "/opt/homebrew/bin/mysqld"]);
      const mysql = program("WCF_MYSQL", ["mysql", "/opt/homebrew/bin/mysql"]);
      mysqlAdmin = program("WCF_MYSQLADMIN", ["mysqladmin", "/opt/homebrew/bin/mysqladmin"]);
      const directory = join(root, "mysql");
      mysqlSocket = join(root, "mysql.sock");
      await run(mysqld, ["--no-defaults", "--initialize-insecure", "--datadir=" + directory]);
      mysqlServer = background(mysqld, ["--no-defaults", "--datadir=" + directory, "--bind-address=127.0.0.1",
        "--port=" + dbPort, "--mysqlx=OFF", "--socket=" + mysqlSocket,
        "--pid-file=" + join(root, "mysql.pid"), "--log-error=" + join(root, "mysql.log")]);
      const args = ["--no-defaults", "--socket=" + mysqlSocket, "--user=root", "--batch", "--skip-column-names"];
      await waitReady(() => run(mysql, [...args, "-e", "SELECT 1"], "", 2000), mysqlServer);
      await run(mysql, [...args, "-e", "CREATE DATABASE wcf_test"]);
      sql = statement => run(mysql, [...args, "wcf_test"], statement);
    } else {
      const initdb = program("WCF_INITDB", ["initdb", pgRoot + "initdb"]);
      const psql = program("WCF_PSQL", ["psql", pgRoot + "psql"]);
      pgCtl = program("WCF_PG_CTL", ["pg_ctl", pgRoot + "pg_ctl"]);
      pgDirectory = join(root, "postgres");
      await run(initdb, ["-D", pgDirectory, "-U", "wcf_test", "-A", "trust", "--encoding=UTF8", "--no-locale"]);
      await run(pgCtl, ["-D", pgDirectory, "-l", join(root, "postgres.log"), "-o", "-h 127.0.0.1 -p " + dbPort + " -k " + root, "start"]);
      const args = ["-h", "127.0.0.1", "-p", String(dbPort), "-U", "wcf_test", "-v", "ON_ERROR_STOP=1", "-At"];
      await run(psql, [...args, "-d", "postgres"], "CREATE DATABASE wcf_test");
      sql = statement => run(psql, [...args, "-d", "wcf_test"], statement);
    }
    await sql(await readFile(join(example, "schema.sql"), "utf8"));
    await sql("CREATE TABLE wcf_audit (owner VARCHAR(128) NOT NULL)");
    const config = join(root, driver + ".toml");
    await writeFile(config, `version = 2
[server]
pid_file = "${root}/vhttpd.pid"
[observability]
event_log = "${root}/events.ndjson"
[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = ${httpPort}
[resources.db.wechat]
kind = "${driver}"
host = "127.0.0.1"
port = ${dbPort}
username = "${driver === "mysql" ? "root" : "wcf_test"}"
password = ""
database = "wcf_test"
pool_size = 4
options = {socket = "${root}/db.sock", pool_name = "wechat"}
[engines.wechat]
kind = "vjsx"
entry = "${example}/tests/entry.mts"
module_root = "${example}"
runtime_profile = "node"
thread_count = 2
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
    const serverEnvironment = {...process.env,
      WECHAT_APP_ID: "test-app", WECHAT_APP_SECRET: "fixture-secret", WECHAT_DB_DRIVER: driver,
      WECHAT_FUNCTION_TIMEOUT_MS: "3000", WECHAT_DATABASE_TIMEOUT_MS: "5000", WCF_TEST_WECHAT_URL: peerUrl,
    };
    vhttpd = background(binary, ["--config", config], serverEnvironment);
    const base = "http://127.0.0.1:" + httpPort;
    await waitReady(async () => { await fetch(base + "/", {signal: AbortSignal.timeout(1000)}); }, vhttpd);
    async function request(path, body, token, extraHeaders = {}) {
      // Independent sockets avoid keep-alive connections being assigned to the
      // same blocking HTTP worker, which can serialize a whole client pool.
      const response = await new Promise((resolve, reject) => {
        const connection = httpRequest(base + path, {
          method: "POST", agent: false, signal: AbortSignal.timeout(15000),
          headers: {"content-type": "application/json", ...(token ? {authorization: "Bearer " + token} : {}), ...extraHeaders},
        }, incoming => {
          let text = "";
          incoming.on("data", data => { text += data; });
          incoming.on("error", reject);
          incoming.on("end", () => resolve({status: incoming.statusCode, text}));
        });
        connection.on("error", reject);
        connection.end(JSON.stringify(body));
      });
      if (peerFailure) throw peerFailure;
      const text = response.text;
      assert.ok(!text.includes("fixture-secret") && !text.includes("SECRET_SESSION_KEY") && !text.includes("PRIVATE_ERROR_MUST_NOT_LEAK"), text);
      return {status: response.status, body: JSON.parse(text)};
    }
    async function login(name) {
      const code = name + "-" + (++sequence);
      const response = await request("/auth/login", {code, openid: "forged", appid: "evil"});
      assert.equal(response.status, 200, JSON.stringify(response));
      assert.match(response.body.token, /^[a-f0-9]{64}$/);
      return {token: response.body.token, code};
    }
    const [alice, bob] = await Promise.all([login("alice"), login("bob")]);
    assert.notEqual(alice.token, bob.token);
    await sql("UPDATE wcf_users SET display_name = 'Alice' WHERE open_id = 'alice'; UPDATE wcf_users SET display_name = 'Bob' WHERE open_id = 'bob'");
    assert.equal((await request("/auth/login", {code: alice.code})).status, 401);
    assert.equal((await request("/auth/login", {code: "bad"})).status, 401);
    assert.equal((await request("/functions/getUser", {openid: "alice"})).status, 401);
    assert.equal((await request("/functions/getUser", {}, "a".repeat(64))).status, 401);
    assert.equal((await request("/functions/../../bad", {}, alice.token)).status, 404);
    let overlappingPairs = 0;
    for (let i = 0; i < 6; i++) {
      const responses = await Promise.all([["alice", alice], ["bob", bob]].map(async ([name, session]) => {
        const response = await request("/functions/delayedIdentity", {
          openid: name === "alice" ? "bob" : "alice", OPENID: "forged", APPID: "evil", context: {OPENID: "forged"}, driver: "bad",
        }, session.token, {"x-wx-openid": "forged", "x-wx-appid": "evil"});
        assert.equal(response.status, 200, JSON.stringify(response));
        const result = response.body.result;
        assert.equal(result.before, name);
        assert.equal(result.after, name);
        assert.equal(result.eventOpenid, name);
        assert.equal(result.eventAppid, "test-app");
        assert.equal(result.hasFakeContext, false);
        assert.equal(result.user.open_id, name);
        assert.ok(result.requestId);
        return response;
      }));
      assert.notEqual(responses[0].body.result.requestId, responses[1].body.result.requestId);
      const [left, right] = responses.map(response => response.body.result);
      assert.notEqual(left.laneId, right.laneId, "requests must use separate lanes");
      if (left.startedAt < right.finishedAt && right.startedAt < left.finishedAt) overlappingPairs++;
    }
    // Transport scheduling need not overlap every pair. Require measured
    // overlapping execution on distinct lanes, not just Promise.all submission.
    assert.ok(overlappingPairs > 0, "no cross-lane overlap was observed");
    console.log(driver + ": concurrent identities / forged identity / invalid sessions: PASS (" + overlappingPairs + " overlapping pairs)");
    assert.equal((await sql("SELECT COUNT(*) FROM wcf_sessions")).trim(), "2");
    assert.equal((await sql("SELECT COUNT(*) FROM wcf_sessions WHERE token_hash IN ('" + alice.token + "','" + bob.token + "')")).trim(), "0");
    for (const [name, expected] of [["failure", 500], ["timeout", 504], ["late", 504]]) {
      const response = await request("/functions/" + name, {}, alice.token);
      assert.equal(response.status, expected, JSON.stringify(response));
      // No grace sleep: rollback must already be visible when HTTP returns.
      assert.equal((await sql("SELECT COUNT(*) FROM wcf_audit")).trim(), "0", name);
      const recovered = await request("/functions/getUser", {}, bob.token);
      assert.equal(recovered.status, 200, JSON.stringify(recovered));
      assert.equal(recovered.body.result.user.display_name, "Bob");
    }
    await pause(1100);
    assert.equal((await sql("SELECT COUNT(*) FROM wcf_audit")).trim(), "0", "late continuation wrote after timeout");
    const successful = await request("/functions/success", {}, alice.token);
    assert.equal(successful.status, 200, JSON.stringify(successful));
    assert.equal((await sql("SELECT COUNT(*) FROM wcf_audit WHERE owner = 'alice'")).trim(), "1");
    await sql("UPDATE wcf_sessions SET expires_ms = 0 WHERE open_id = 'alice'");
    assert.equal((await request("/functions/getUser", {}, alice.token)).status, 401);
    assert.equal((await request("/functions/getUser", {}, bob.token)).status, 200);
    console.log(driver + ": exception / timeout / late SQL rollback / commit / expiry / pool reuse: PASS");
    await stop(vhttpd); vhttpd = undefined;
    // Exercise the actual production entry, not just the fixture registry.
    // The same persisted token must survive the process/lane restart.
    await writeFile(config, (await readFile(config, "utf8")).replace(example + "/tests/entry.mts", example + "/app.mts"));
    vhttpd = background(binary, ["--config", config], serverEnvironment);
    await waitReady(async () => { await fetch(base + "/", {signal: AbortSignal.timeout(1000)}); }, vhttpd);
    const persisted = await request("/functions/getUser", {}, bob.token);
    assert.equal(persisted.status, 200, JSON.stringify(persisted));
    assert.equal(persisted.body.result.openid, "bob");
    assert.equal((await request("/functions/failure", {}, bob.token)).status, 404);
    console.log(driver + ": production entry / session persistence / no test routes: PASS");
    await stop(vhttpd); vhttpd = undefined;
    if (driver === "mysql") {
      await run(mysqlAdmin, ["--no-defaults", "--socket=" + mysqlSocket, "--user=root", "shutdown"]);
      await stop(mysqlServer); mysqlServer = undefined;
    } else {
      await run(pgCtl, ["-D", pgDirectory, "-m", "fast", "stop"]); pgDirectory = undefined;
    }
  }
  console.log("All application E2E checks passed; no vhttpd/vjsx core changes.");
} catch (error) {
  console.error(logs.join("").slice(-24000));
  throw error;
} finally {
  await stop(vhttpd);
  if (mysqlServer) {
    try { await run(mysqlAdmin, ["--no-defaults", "--socket=" + mysqlSocket, "--user=root", "shutdown"], "", 5000); } catch (_) {}
    await stop(mysqlServer);
  }
  if (pgDirectory) { try { await run(pgCtl, ["-D", pgDirectory, "-m", "fast", "stop"], "", 10000); } catch (_) {} }
  peer.closeAllConnections();
  await new Promise(resolve => peer.close(resolve));
  if (process.env.WCF_KEEP_TEST_FILES === "1") console.log("Test files retained: " + root);
  else await rm(root, {recursive: true, force: true});
}
