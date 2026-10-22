import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

test('probe consumes frames coalesced with the HTTP upgrade', { timeout: 5000 }, async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), 'vhttpd-upgrade-head-'));
  const output = path.join(dir, 'probe.json');
  const child = fork(new URL('./provider_ws_upstream_probe.mjs', import.meta.url), ['0', '0', output]);
  let socket;
  t.after(async () => {
    socket?.destroy();
    if (child.exitCode === null) child.kill();
    await rm(dir, { recursive: true, force: true });
  });
  const exited = once(child, 'exit');
  const [{ openPort, wsPort }] = await once(child, 'message');
  await fetch(`http://127.0.0.1:${openPort}/callback/ws/endpoint`);
  socket = net.connect(wsPort, '127.0.0.1');
  await once(socket, 'connect');
  // Send both frames in the same write as the upgrade headers. Node puts them
  // in upgrade's head buffer rather than re-emitting a data event.
  const frame = (opcode, payload) => {
    const body = Buffer.from(payload);
    const mask = Buffer.from([1, 2, 3, 4]);
    const masked = Buffer.from(body.map((byte, i) => byte ^ mask[i % 4]));
    return Buffer.concat([Buffer.from([0x80 | opcode, 0x80 | body.length]), mask, masked]);
  };
  socket.write(Buffer.concat([
    Buffer.from('GET /callback HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n'),
    frame(1, '{"type":"hello"}'),
    frame(2, 'ack'),
  ]));
  assert.equal((await exited)[0], 0);
  const state = JSON.parse(await readFile(output, 'utf8'));
  assert.equal(state.handshakeType, 'hello');
  assert.equal(state.pushed, true);
  assert.equal(state.ack, true);
});
