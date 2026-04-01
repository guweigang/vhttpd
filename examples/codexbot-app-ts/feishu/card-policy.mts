import { CODEX_MESSAGE_PHASE } from "../codex/protocol.mts";

export function isThreadScopedSession(sessionKey) {
  return typeof sessionKey === "string" && sessionKey.includes("::thread:");
}

export function threadRootIdFromSessionKey(sessionKey) {
  if (!isThreadScopedSession(sessionKey)) {
    return "";
  }
  const parts = String(sessionKey).split("::thread:");
  return parts.length > 1 ? parts[1].trim() : "";
}

export function isItemLifecycleNotification(notification) {
  const method = typeof notification?.method === "string" ? notification.method : "";
  return method.startsWith("item/")
    || method.startsWith("rawResponseItem/")
    || (method === "turn/completed" && (notification?.finalText || notification?.message));
}

export function notificationItemKey(notification) {
  if (typeof notification?.itemId === "string" && notification.itemId.trim() !== "") {
    return `item:${notification.itemId.trim()}`;
  }
  const turnId = typeof notification?.turnId === "string" ? notification.turnId.trim() : "";
  const phase = typeof notification?.phase === "string" ? notification.phase.trim() : "";
  const method = typeof notification?.method === "string" ? notification.method.trim() : "";
  if (!turnId && !phase && !method) {
    return "";
  }
  return `synthetic:${turnId || "-"}:${phase || "-"}:${method || "-"}`;
}

export function shouldRenderAssistantContentInItemStream(notification, enableItemRenderStreams = false) {
  if (!enableItemRenderStreams) {
    return false;
  }
  const method = typeof notification?.method === "string" ? notification.method : "";
  if (method === "error" || method === "thread/status/changed") {
    return false;
  }
  return isItemLifecycleNotification(notification)
    || notification?.phase === CODEX_MESSAGE_PHASE.COMMENTARY
    || notification?.phase === CODEX_MESSAGE_PHASE.FINAL_ANSWER
    || notification?.itemType === "agentMessage"
    || (notification?.itemType === "message" && notification?.itemRole === "assistant");
}
