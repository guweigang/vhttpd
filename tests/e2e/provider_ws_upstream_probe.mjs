import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";

const openPort = Number(process.argv[2]);
const wsPort = Number(process.argv[3]);
const outFile = process.argv[4];
if (!Number.isInteger(openPort) || !Number.isInteger(wsPort) || !outFile) {
  console.error("usage: node provider-ws-upstream.mjs <open-port> <ws-port> <out-file>");
  process.exit(2);
}

const state = {
  endpointRequested: false,
  handshake: "",
  handshakeType: "",
  pushed: false,
  ack: false,
};
let probeTimeout;

function varint(value) {
  let current = BigInt(value);
  const out = [];
  for (;;) {
    if ((current & ~0x7fn) === 0n) {
      out.push(Number(current));
      return Buffer.from(out);
    }
    out.push(Number((current & 0x7fn) | 0x80n));
    current >>= 7n;
  }
}

function fieldKey(field, wire) {
  return varint((BigInt(field) << 3n) | BigInt(wire));
}

function bytesField(field, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload));
  return Buffer.concat([fieldKey(field, 2), varint(body.length), body]);
}

function stringField(field, payload) {
  return bytesField(field, Buffer.from(String(payload)));
}

function header(key, value) {
  return Buffer.concat([stringField(1, key), stringField(2, value)]);
}

function feishuPushFrame() {
  const payload = JSON.stringify({
    schema: "2.0",
    header: {
      event_id: "evt-provider-ws-upstream",
      event_type: "im.message.receive_v1",
    },
    event: {
      sender: {
        sender_id: { open_id: "ou_provider_ws_upstream" },
        tenant_key: "tenant_provider_ws_upstream",
      },
      message: {
        message_id: "om-provider-ws-upstream",
        message_type: "text",
        chat_id: "oc-provider-ws-upstream",
        chat_type: "group",
        create_time: "1710000000",
        content: JSON.stringify({ text: "hello from fake upstream" }),
      },
    },
  });
  return Buffer.concat([
    fieldKey(1, 0), varint(1701),
    fieldKey(4, 0), varint(1),
    bytesField(5, header("type", "event")),
    bytesField(5, header("trace_id", "trace-provider-ws-upstream")),
    bytesField(5, header("seq", "1701")),
    stringField(6, "json"),
    stringField(7, "application/json"),
    bytesField(8, Buffer.from(payload)),
    stringField(9, "provider-ws-upstream"),
  ]);
}

function wsFrame(opcode, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload));
  const head = [];
  head.push(0x80 | opcode);
  if (body.length < 126) {
    head.push(body.length);
  } else if (body.length < 65536) {
    head.push(126, (body.length >> 8) & 0xff, body.length & 0xff);
  } else {
    throw new Error("test frame too large");
  }
  return Buffer.concat([Buffer.from(head), body]);
}

function parseClientFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    throw new Error("large test frames are unsupported");
  }
  const mask = masked ? buffer.subarray(offset, offset + 4) : null;
  if (masked) offset += 4;
  if (buffer.length < offset + length) return null;
  const payload = Buffer.from(buffer.subarray(offset, offset + length));
  if (mask) {
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
  }
  return { opcode, payload, consumed: offset + length };
}

async function finish() {
  clearTimeout(probeTimeout);
  await fs.writeFile(outFile, JSON.stringify(state));
  openServer.close();
  wsServer.close();
  setTimeout(() => process.exit(state.endpointRequested && state.handshake && state.pushed && state.ack ? 0 : 1), 25);
}

const openServer = http.createServer((req, res) => {
  if (req.url.includes("/callback/ws/endpoint")) {
    state.endpointRequested = true;
    res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({
      code: 0,
      msg: "ok",
      data: {
        URL: `ws://127.0.0.1:${wsServer.address().port}/callback`,
        ClientConfig: { PingInterval: 60, ReconnectInterval: 60, ReconnectNonce: 1, ReconnectCount: 1 },
      },
    }));
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

const wsServer = http.createServer();
wsServer.on("upgrade", (req, socket, head) => {
  // Bound the protocol exchange, not vhttpd's cold startup before connecting.
  probeTimeout ??= setTimeout(async () => {
    await fs.writeFile(outFile, JSON.stringify(state));
    process.exit(1);
  }, 10000);
  const key = req.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "\r\n",
  ].join("\r\n"));
  let pending = Buffer.alloc(0);
  const consume = (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    for (;;) {
      const frame = parseClientFrame(pending);
      if (!frame) return;
      pending = pending.subarray(frame.consumed);
      if (frame.opcode === 1) {
        state.handshake = frame.payload.toString("utf8");
        try {
          state.handshakeType = JSON.parse(state.handshake).type || "";
        } catch {
          state.handshakeType = "";
        }
        socket.write(wsFrame(2, feishuPushFrame()));
        state.pushed = true;
      } else if (frame.opcode === 2) {
        state.ack = true;
        finish().catch((err) => {
          console.error(err);
          process.exit(1);
        });
      }
    }
  };
  socket.on("data", consume);
  // HTTP parsing can consume the first WebSocket frame in the upgrade read.
  // These bytes will never be emitted again as socket data.
  if (head.length) consume(head);
});

await Promise.all([
  new Promise((resolve) => openServer.listen(openPort, "127.0.0.1", resolve)),
  new Promise((resolve) => wsServer.listen(wsPort, "127.0.0.1", resolve)),
]);
process.send?.({ openPort: openServer.address().port, wsPort: wsServer.address().port });

