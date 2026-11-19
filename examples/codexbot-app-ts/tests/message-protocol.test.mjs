import test from "node:test";
import assert from "node:assert/strict";
import { createMessageProtocolAdapter } from "../lib/message-protocol.mjs";
function frame(provider, eventType, payload, extras = {}) {
  return { provider, eventType, instance: "one", traceId: "", payloadJson: () => payload, runtime: { warn() {} }, ...extras };
}
test("application resolves thread/turn messages with instance isolation and preserves raw payload", async () => {
  const raw = { method: "item/agentMessage/delta", params: { threadId: "t", turnId: "u", itemId: "i", delta: "hello", future: true } };
  const calls = [];
  const adapter = createMessageProtocolAdapter({ resolveStream: async (...args) => { calls.push(args); return "s"; } });
  const input = Object.freeze(frame("codex", "codex.notification", raw));
  const result = await adapter.adapt(input);
  assert.equal(result.traceId, "s");
  assert.equal(input.traceId, "");
  assert.equal(result.payloadJson(), raw);
  assert.deepEqual(calls, [["one", "t", "u"]]);
});
test("unknown methods and invalid consumed fields produce bounded diagnostics without private contents", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => "s" });
  assert.equal(await adapter.adapt(frame("codex", "codex.notification", {method:"future/new",params:{secret:"private"}})), null);
  assert.equal(await adapter.adapt(frame("codex", "codex.notification", {method:"item/agentMessage/delta",params:{delta:42}})), null);
  assert.equal(adapter.snapshot().unknown, 1);
  assert.equal(adapter.snapshot().invalid, 1);
  assert.ok(!JSON.stringify(adapter.snapshot()).includes("private"));
});
test("an unbound thread never falls back to an unrelated active stream", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => "" });
  assert.equal(await adapter.adapt(frame("codex", "codex.server_request", {id:1,method:"item/commandExecution/requestApproval",params:{threadId:"other"}})), null);
  assert.equal(adapter.snapshot().unrouted, 1);
});
test("Feishu event selection belongs to application and tolerates added optional fields", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => "" });
  const message = Object.freeze(frame("feishu", "feishu.event", {header:{event_type:"im.message.receive_v1"},event:{message:{content:'{"text":"hello"}',extra:1}}}));
  assert.equal((await adapter.adapt(message)).eventType, "im.message.receive_v1");
  const card = frame("feishu", "feishu.event", {header:{event_type:"card.action.trigger"},event:{action:{value:{kind:"test"}}}});
  assert.equal((await adapter.adapt(card)).event, "action");
  assert.equal(await adapter.adapt(frame("feishu", "feishu.event", {header:{event_type:"future.event"},event:{}})), null);
});
test("legacy correlated frames retain routing and error responses reach the existing RPC router", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => { throw Error("unexpected lookup"); } });
  const notification = frame("codex", "codex.notification", {method:"turn/completed",params:{}}, {traceId:"s"});
  assert.equal(await adapter.adapt(notification), notification);
  const rpc = frame("codex", "codex.rpc.response", {method:"turn/start",has_error:true,result:{message:"failure"}}, {traceId:"s"});
  assert.equal(await adapter.adapt(rpc), rpc);
});

test("method catalog stays aligned with application-vendored protocol declarations", async () => {
  const { readFile } = await import("node:fs/promises");
  const { notificationMethods, requestMethods } = await import("../lib/protocol-methods.mjs");
  for (const [filename, methods] of [["ServerNotification.ts", notificationMethods], ["ServerRequest.ts", requestMethods]]) {
    const text = await readFile(new URL(`../codex/ts/${filename}`, import.meta.url), "utf8");
    const declared = [...text.matchAll(/"method": "([^"]+)"/g)].map((match) => match[1]);
    assert.deepEqual(methods, declared);
  }
});

test("operational Codex notifications, Feishu read events and internal receipts are explicitly ignored", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => { throw Error("unexpected routing"); } });
  for (const method of ["remoteControl/status/changed", "mcpServer/startupStatus/updated"]) {
    assert.equal(await adapter.adapt(frame("codex", "codex.notification", {method, params:{}})), null);
  }
  assert.equal(await adapter.adapt(frame("feishu", "feishu.event", {header:{event_type:"im.message.message_read_v1"},event:{}})), null);
  assert.equal(await adapter.adapt(frame("feishu", "feishu.message.sent", null)), null);
  assert.equal(adapter.snapshot().ignored, 4);
  assert.equal(adapter.snapshot().unknown, 0);
});

test("approval resolution reaches its request router after the parent turn has stopped", async () => {
  const adapter = createMessageProtocolAdapter({ resolveStream: async () => { throw Error("resolution must not depend on active stream"); } });
  const notification = frame("codex", "codex.notification", {method:"serverRequest/resolved",params:{threadId:"thread",requestId:1}});
  assert.equal(await adapter.adapt(notification),notification);
  assert.equal(adapter.snapshot().unrouted,0);
});
