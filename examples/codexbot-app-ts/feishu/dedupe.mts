export function createFeishuInboundDeduper(options = {}) {
  const recentInboundCache = new Map();
  const dedupeWindowMs = Number(options.dedupeWindowMs) > 0 ? Number(options.dedupeWindowMs) : 2 * 60 * 1000;
  const dedupeLimit = Number(options.dedupeLimit) > 0 ? Number(options.dedupeLimit) : 1024;
  const rememberInboundEvent = typeof options.rememberInboundEvent === "function"
    ? options.rememberInboundEvent
    : async () => false;

  function prune(nowMs = Date.now()) {
    for (const [key, value] of recentInboundCache.entries()) {
      if (!value || (nowMs - value.seenAt) > dedupeWindowMs) {
        recentInboundCache.delete(key);
      }
    }
    if (recentInboundCache.size <= dedupeLimit) {
      return;
    }
    const entries = [...recentInboundCache.entries()]
      .sort((left, right) => (left[1]?.seenAt || 0) - (right[1]?.seenAt || 0));
    const overflow = recentInboundCache.size - dedupeLimit;
    for (let index = 0; index < overflow; index += 1) {
      recentInboundCache.delete(entries[index][0]);
    }
  }

  function normalizeText(value) {
    return typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  }

  function dedupeKeys(inbound) {
    const keys = [];
    const eventId = typeof inbound?.eventId === "string" ? inbound.eventId.trim() : "";
    const chatId = typeof inbound?.chatId === "string" ? inbound.chatId.trim() : "";
    const messageId = typeof inbound?.messageId === "string" ? inbound.messageId.trim() : "";
    const sessionKey = typeof inbound?.sessionKey === "string" ? inbound.sessionKey.trim() : "";
    const text = normalizeText(inbound?.text);
    const senderOpenId = typeof inbound?.senderOpenId === "string" ? inbound.senderOpenId.trim() : "";
    const createTime = typeof inbound?.createTime === "string" ? inbound.createTime.trim() : "";
    const threadKey = typeof inbound?.threadKey === "string" ? inbound.threadKey.trim() : "";
    if (eventId) {
      keys.push(`event:${eventId}`);
    }
    if (chatId && messageId) {
      keys.push(`message:${chatId}::${messageId}`);
    }
    if (chatId && threadKey && messageId) {
      keys.push(`thread-message:${chatId}::${threadKey}::${messageId}`);
    }
    if (sessionKey && senderOpenId && createTime) {
      keys.push(`created:${sessionKey}::${senderOpenId}::${createTime}`);
    } else if (chatId && createTime) {
      keys.push(`created:${chatId}::${createTime}`);
    }
    if (!keys.length && sessionKey && text) {
      keys.push(`fallback:${sessionKey}::${senderOpenId || "unknown"}::${text}`);
    }
    return [...new Set(keys)];
  }

  async function shouldIgnore(inbound) {
    const keys = dedupeKeys(inbound);
    if (!keys.length) {
      return false;
    }
    const nowMs = Date.now();
    prune(nowMs);
    for (const key of keys) {
      const existing = recentInboundCache.get(key);
      if (existing && (nowMs - existing.seenAt) <= dedupeWindowMs) {
        return true;
      }
    }
    for (const key of keys) {
      const alreadySeen = await rememberInboundEvent(key, dedupeWindowMs);
      if (alreadySeen) {
        for (const cacheKey of keys) {
          recentInboundCache.set(cacheKey, {
            seenAt: nowMs,
          });
        }
        return true;
      }
    }
    for (const key of keys) {
      recentInboundCache.set(key, {
        seenAt: nowMs,
      });
    }
    return false;
  }

  return {
    shouldIgnore,
  };
}
