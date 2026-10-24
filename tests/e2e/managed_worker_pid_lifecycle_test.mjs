import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { if (e.code === 'ESRCH') return false; throw e; } };
async function port() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const value = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return value;
}
async function until(fn, message, timeout = 25000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await fn()) return; await delay(100); }
  throw new Error(message);
}
for (const signal of ['SIGTERM', 'SIGINT']) {
  test(`managed worker restart and ${signal} cleanup retire every PID`, {timeout: 90000}, async () => {
    const root = fs.mkdtempSync('/tmp/vhttpd-pids-');
    const fd = fs.openSync(path.join(root, 'server.log'), 'w');
    const pids = [];
    let server;
    let exited;
    try {
      const web = await port();
      const admin = await port();
      const app = path.join(root, 'app.php');
      fs.writeFileSync(app, '<?php return static fn(array $req): array => ["status"=>200,"body"=>"ok"];');
      const cfg = path.join(root, 'server.toml');
      fs.writeFileSync(cfg, `[server]\nhost = "127.0.0.1"\nport = ${web}\n[files]\npid_file = "${root}/server.pid"\nevent_log = "${root}/events.ndjson"\ninternal_admin_socket = "${root}/admin.sock"\n[worker]\nautostart = true\npool_size = 1\nsocket = "${root}/worker.sock"\ncmd = "php ${repo}/php/package/bin/vphp-worker"\n[worker.env]\nVHTTPD_APP = "${app}"\n[executor]\nkind = "php"\n[php]\nworker_entry = "${repo}/php/package/bin/vphp-worker"\napp_entry = "${app}"\n[admin]\nhost = "127.0.0.1"\nport = ${admin}\ntoken = ""\n`);
      server = spawn(binary, ['--config', cfg], {stdio: ['ignore', fd, fd]});
      exited = new Promise(resolve => server.once('exit', (code, sig) => resolve({code, sig})));
      const url = `http://127.0.0.1:${admin}`;
      let current;
      const snapshot = async () => {
        if (server.exitCode !== null) throw new Error(`server exited during startup: ${server.exitCode}`);
        try {
          const res = await fetch(`${url}/admin/workers`, {signal: AbortSignal.timeout(1000)});
          const data = await res.json();
          const worker = data.workers?.[0];
          if (worker?.alive && worker.pid > 0) { current = worker.pid; return true; }
        } catch {}
        return false;
      };
      await until(snapshot, 'initial worker not ready');
      const initial = current;
      pids.push(initial);
      const restart = await fetch(`${url}/admin/workers/restart?id=0`, {method: 'POST', signal: AbortSignal.timeout(10000)});
      assert.equal(restart.status, 200);
      await until(async () => await snapshot() && current !== initial, 'replacement worker not ready');
      pids.push(current);
      await until(() => !alive(initial), 'old worker PID remained after restart', 5000);
      const replacement = current;
      server.kill(signal);
      await until(() => server.exitCode !== null || server.signalCode !== null, 'server shutdown timed out', 10000);
      const result = await exited;
      assert.equal(result.code, signal === 'SIGTERM' ? 143 : 130);
      await until(() => !alive(replacement), 'replacement worker survived server signal cleanup', 5000);
      assert.ok(!fs.existsSync(path.join(root, 'server.pid')));
    } catch (error) {
      error.message += `\n${fs.readFileSync(path.join(root, 'server.log'), 'utf8')}`;
      throw error;
    } finally {
      if (server && server.exitCode === null) {
        server.kill('SIGTERM');
        await Promise.race([exited, delay(3000)]);
        if (server.exitCode === null) { server.kill('SIGKILL'); await exited; }
      }
      // A failed regression must only clean processes whose command still names this fixture.
      for (const pid of pids) {
        try {
          if (execFileSync('ps', ['-p', String(pid), '-o', 'command='], {encoding: 'utf8'}).includes(root)) process.kill(-pid, 'SIGKILL');
        } catch {}
      }
      fs.closeSync(fd);
      fs.rmSync(root, {recursive: true, force: true});
    }
  });
}
