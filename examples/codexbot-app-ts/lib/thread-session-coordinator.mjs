export function createThreadSessionCoordinator(deps) {
  const threadNameCache = new Map();
  const pendingThreadRenameCache = new Map();

  function rememberThreadName(threadId, value) {
    const key = typeof threadId === "string" ? threadId.trim() : "";
    const name = typeof value === "string" ? value.trim() : "";
    if (!key || !name) {
      return;
    }
    threadNameCache.set(key, name);
  }

  function lookupThreadName(threadId) {
    const key = typeof threadId === "string" ? threadId.trim() : "";
    if (!key) {
      return "";
    }
    return threadNameCache.get(key) || "";
  }

  function deleteThreadName(threadId) {
    const key = typeof threadId === "string" ? threadId.trim() : "";
    if (!key) {
      return false;
    }
    return threadNameCache.delete(key);
  }

  function rememberPendingThreadRename(threadId, previousName, nextName) {
    const key = typeof threadId === "string" ? threadId.trim() : "";
    if (!key) {
      return;
    }
    pendingThreadRenameCache.set(key, {
      previousName: typeof previousName === "string" ? previousName.trim() : "",
      nextName: typeof nextName === "string" ? nextName.trim() : "",
    });
  }

  function consumePendingThreadRename(threadId) {
    const key = typeof threadId === "string" ? threadId.trim() : "";
    if (!key) {
      return undefined;
    }
    const pending = pendingThreadRenameCache.get(key);
    pendingThreadRenameCache.delete(key);
    return pending;
  }

  async function continueQueuedTurnStart(streamId, threadId, threadPath = "", options = {}) {
    if (!streamId || !threadId) {
      return [];
    }
    let latest = await deps.getStreamState(streamId);
    if (!latest || latest.turnId) return [];
    // thread/started may precede the resume response. It cannot start the prompt.
    const allowed = options.resumed ? ["resuming_thread"] : ["queued", "thread_ready", "thread_ready_notified"];
    if (latest.status && !allowed.includes(latest.status)) return [];
    if (options.resumed) {
      const current = await deps.ensureChatState(latest.sessionKey, latest.chatId);
      if (current.threadId !== threadId || current.lastStreamId !== streamId) return [];
    }
    const bound = await deps.bindThreadToStream(streamId, threadId, threadPath || "");
    latest = bound?.stream || await deps.getStreamState(streamId);
    if (!latest) return [];
    await deps.finalizeStreamState(streamId, {
      status: "starting_turn",
      threadPath: threadPath || latest.threadPath || "",
      lastEvent: "turn/start.requested",
    });
    const chat = await deps.ensureChatState(latest.sessionKey, latest.chatId);
    const defaults = deps.botDefaults();
    const instance = deps.fallbackCodexInstance(latest.codexInstance || chat.codexInstance, defaults);
    return [
      deps.codexTurnStart(
        deps.buildTurnStartParams(
          {
            ...latest,
            threadId,
          },
          {
            ...chat,
            threadId,
          },
          defaults,
        ),
        streamId,
        instance,
      ),
    ];
  }

  return {
    consumePendingThreadRename,
    continueQueuedTurnStart,
    deleteThreadName,
    lookupThreadName,
    rememberPendingThreadRename,
    rememberThreadName,
  };
}
