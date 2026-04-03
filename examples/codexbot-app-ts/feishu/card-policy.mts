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
    || method === "thread/realtime/itemAdded"
    || (method === "turn/completed" && (notification?.finalText || notification?.message));
}

export function notificationItemKey(notification) {
  const turnId = typeof notification?.turnId === "string" ? notification.turnId.trim() : "";
  const phase = typeof notification?.phase === "string" ? notification.phase.trim() : "";
  const method = typeof notification?.method === "string" ? notification.method.trim() : "";
  const itemType = typeof notification?.itemType === "string" ? notification.itemType.trim() : "";
  if (itemType === "reasoning" || method.startsWith("item/reasoning/")) {
    return `progress:${turnId || "-"}:reasoning`;
  }
  if (itemType === "plan" || method.startsWith("item/plan/")) {
    return `progress:${turnId || "-"}:plan`;
  }
  if (typeof notification?.itemId === "string" && notification.itemId.trim() !== "") {
    return `item:${notification.itemId.trim()}`;
  }
  if (!turnId && !phase && !method) {
    return "";
  }
  return `synthetic:${turnId || "-"}:${phase || "-"}:${method || "-"}`;
}

function assistantCapableItem(notification) {
  const itemType = typeof notification?.itemType === "string" ? notification.itemType.trim() : "";
  const itemRole = typeof notification?.itemRole === "string" ? notification.itemRole.trim() : "";
  const phase = typeof notification?.phase === "string" ? notification.phase.trim() : "";
  const method = typeof notification?.method === "string" ? notification.method.trim() : "";
  return itemType === "agentMessage"
    || method.startsWith("item/agentMessage")
    || (itemType === "message" && itemRole === "assistant")
    || phase === CODEX_MESSAGE_PHASE.COMMENTARY
    || phase === CODEX_MESSAGE_PHASE.FINAL_ANSWER;
}

function progressCapableItem(notification) {
  const itemType = typeof notification?.itemType === "string" ? notification.itemType.trim() : "";
  const method = typeof notification?.method === "string" ? notification.method.trim() : "";
  return itemType === "reasoning"
    || itemType === "plan"
    || method.startsWith("item/reasoning/")
    || method.startsWith("item/plan/");
}

function plainPromptVisibleItem(notification) {
  return assistantCapableItem(notification) || progressCapableItem(notification);
}

export function shouldRenderPlainPromptItemStream(notification) {
  const itemId = typeof notification?.itemId === "string" ? notification.itemId.trim() : "";
  if (!itemId) {
    return false;
  }
  const method = typeof notification?.method === "string" ? notification.method.trim() : "";
  if (!method.startsWith("item/") && !method.startsWith("rawResponseItem/") && method !== "thread/realtime/itemAdded") {
    return false;
  }
  const delta = typeof notification?.delta === "string" ? notification.delta.trim() : "";
  const message = typeof notification?.message === "string" ? notification.message.trim() : "";
  const visibleItem = plainPromptVisibleItem(notification);
  if (!visibleItem && !delta && !message) {
    return false;
  }
  if (method.endsWith("/started") || method === "thread/realtime/itemAdded") {
    return visibleItem;
  }
  if (visibleItem && (method.startsWith("item/reasoning/") || method.startsWith("item/plan/"))) {
    return true;
  }
  if (delta) {
    return visibleItem;
  }
  if (visibleItem && message && method !== "item/completed" && method !== "rawResponseItem/completed") {
    return true;
  }
  if (method.startsWith("rawResponseItem/") && message && visibleItem) {
    return true;
  }
  return false;
}

export function shouldRenderAssistantContentInItemStream(notification, enableItemRenderStreams = false) {
  if (!enableItemRenderStreams) {
    return false;
  }
  const method = typeof notification?.method === "string" ? notification.method : "";
  if (method === "error" || method === "thread/status/changed") {
    return false;
  }
  const delta = typeof notification?.delta === "string" ? notification.delta.trim() : "";
  const message = typeof notification?.message === "string" ? notification.message.trim() : "";
  const finalText = typeof notification?.finalText === "string" ? notification.finalText.trim() : "";
  return plainPromptVisibleItem(notification)
    || delta !== ""
    || message !== ""
    || finalText !== "";
}
