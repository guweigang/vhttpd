import { notificationMethods, requestMethods } from "./protocol-methods.mjs";
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const safeMethod = (value) => typeof value === "string" && /^[a-zA-Z0-9/_.-]{1,120}$/.test(value) ? value : "<invalid-method>";
const notifications = new Set(notificationMethods);
const requests = new Set(requestMethods);
// Operational notifications verified against Codex CLI 0.166.0's exported
// ServerNotification schema; they do not change this bot's conversation state.
const ignoredCodexNotifications = new Set(["remoteControl/status/changed", "mcpServer/startupStatus/updated"]);
const ignoredFeishuEvents = new Set(["im.chat.access_event.bot_p2p_chat_entered_v1", "im.message.message_read_v1"]);
const internalFeishuReceipts = new Set(["feishu.message.sent", "feishu.message.updated"]);

// This adapter owns event meaning; native providers only supply envelopes.
// Diagnostics are bounded and local to this worker lane, without message contents.
export function createMessageProtocolAdapter({ resolveStream }) {
  const diagnostics = {
    scope: "worker_lane", checked: 0, ignored: 0, unknown: 0, invalid: 0, unrouted: 0,
    lastIssue: null,
  };
  function issue(frame, code, method) {
    diagnostics[code]++;
    diagnostics.lastIssue = { provider: frame.provider, code, method: safeMethod(method) };
    // Sample repeated failures, never log payloads or RPC error bodies.
    const count = diagnostics[code];
    if (count === 1 || (count & (count - 1)) === 0) {
      frame.runtime?.warn?.("codexbot protocol", code, safeMethod(method));
    }
    return null;
  }
  return {
    snapshot: () => ({ ...diagnostics, lastIssue: diagnostics.lastIssue && { ...diagnostics.lastIssue } }),
    async adapt(frame) {
      if (!["codex", "feishu"].includes(frame.provider)) return frame;
      diagnostics.checked++;
      if (frame.provider === "feishu" && internalFeishuReceipts.has(frame.eventType)) {
        diagnostics.ignored++;
        return null;
      }
      let payload;
      try { payload = frame.payloadJson(null); } catch (_) { return issue(frame, "invalid", ""); }
      if (!object(payload)) return issue(frame, "invalid", "");
      if (frame.provider === "feishu") {
        const eventType = frame.eventType === "feishu.event" ? payload.header?.event_type : frame.eventType;
        if (ignoredFeishuEvents.has(eventType)) { diagnostics.ignored++; return null; }
        if (!["im.message.receive_v1", "card.action.trigger"].includes(eventType)) return issue(frame, "unknown", eventType);
        if (!object(payload.event)) return issue(frame, "invalid", eventType);
        if (eventType === "im.message.receive_v1" && (!object(payload.event.message) || typeof payload.event.message.content !== "string")) return issue(frame, "invalid", eventType);
        if (eventType === "card.action.trigger" && !object(payload.event.action)) return issue(frame, "invalid", eventType);
        return Object.create(frame, {
          eventType: { value: eventType, enumerable: true },
          event: { value: eventType === "card.action.trigger" ? "action" : "message", enumerable: true },
        });
      }
      if (frame.eventType === "codex.rpc.response") {
        if (typeof payload.method !== "string" || typeof payload.has_error !== "boolean") return issue(frame, "invalid", payload.method);
        return frame;
      }
      if (frame.eventType === "codex.notification" && ignoredCodexNotifications.has(payload.method)) {
        if (!object(payload.params)) return issue(frame, "invalid", payload.method);
        diagnostics.ignored++;
        return null;
      }
      const known = frame.eventType === "codex.server_request" ? requests : notifications;
      if (!known.has(payload.method)) return issue(frame, "unknown", payload.method);
      if (!object(payload.params)) return issue(frame, "invalid", payload.method);
      const params = payload.params;
      for (const key of ["threadId", "turnId", "itemId", "delta"]) {
        if (key in params && typeof params[key] !== "string") return issue(frame, "invalid", payload.method);
      }
      const threadId = params.threadId || params.thread?.id || "";
      const turnId = params.turnId || params.turn?.id || "";
      if (typeof threadId !== "string" || typeof turnId !== "string") return issue(frame, "invalid", payload.method);
      // Approval resolution is correlated by thread/request ID in its own router,
      // including after the parent turn has already stopped.
      if (frame.eventType === "codex.notification" && payload.method === "serverRequest/resolved") return frame;
      // Correlated responses and legacy frames already carry a stream identifier.
      if (frame.traceId) return frame;
      const streamId = await resolveStream(frame.instance || "main", threadId, turnId);
      if (!streamId) {
        // Account/config notifications need no stream. Let application handlers decide.
        if (!threadId) return frame;
        return issue(frame, "unrouted", payload.method);
      }
      return Object.create(frame, { traceId: { value: streamId, enumerable: true } });
    },
  };
}
