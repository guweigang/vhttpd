export function createItemRenderCoordinator(deps) {
  function itemStreamPrompt(parentStream, notification) {
    const labels = [];
    if (notification?.phase) {
      labels.push(notification.phase);
    }
    if (notification?.itemId) {
      labels.push(notification.itemId);
    } else if (notification?.turnId) {
      labels.push(notification.turnId);
    }
    const suffix = labels.length ? ` [${labels.join(" ")}]` : " [item]";
    return `${parentStream.prompt || "codex item"}${suffix}`;
  }

  function openItemStreamCard(parentStream, itemStreamId) {
    const threadRootId = deps.threadRootIdFromSessionKey(parentStream?.sessionKey || "");
    if (threadRootId) {
      return deps.feishuText(threadRootId, " ", itemStreamId, "message_id");
    }
    return deps.feishuText(parentStream.chatId, " ", itemStreamId, "chat_id");
  }

  async function ensureNotificationItemRender(parentStream, notification) {
    if (!deps.enableItemRenderStreams) {
      return undefined;
    }
    if (!parentStream || !deps.isItemLifecycleNotification(notification)) {
      return undefined;
    }
    const itemKey = deps.notificationItemKey(notification);
    if (!itemKey) {
      return undefined;
    }
    let itemRender = await deps.getItemRenderState(parentStream.streamId, itemKey);
    if (itemRender?.itemStreamId) {
      const itemStream = await deps.getStreamState(itemRender.itemStreamId);
      if (itemStream) {
        return {
          itemKey,
          itemRender,
          itemStream,
          opened: false,
        };
      }
    }
    const itemStream = await deps.createDerivedStreamState(parentStream.streamId, {
      prompt: itemStreamPrompt(parentStream, notification),
      codexInstance: parentStream.codexInstance || "",
      threadId: notification.threadId || parentStream.threadId || "",
      threadPath: notification.threadPath || parentStream.threadPath || "",
      turnId: notification.turnId || parentStream.turnId || "",
      status: "queued",
      lastEvent: notification.method || "codex.notification",
    });
    if (!itemStream) {
      return undefined;
    }
    itemRender = await deps.upsertItemRenderState(parentStream.streamId, itemKey, {
      itemId: notification.itemId || "",
      turnId: notification.turnId || parentStream.turnId || "",
      phase: notification.phase || "",
      itemStreamId: itemStream.streamId,
      status: "open",
    });
    return {
      itemKey,
      itemRender,
      itemStream,
      opened: true,
    };
  }

  function shouldAppendItemText(itemStream, text) {
    if (typeof text !== "string" || text.trim() === "") {
      return false;
    }
    const current = typeof itemStream?.draft === "string" && itemStream.draft.trim() !== ""
      ? itemStream.draft.trim()
      : typeof itemStream?.resultText === "string"
        ? itemStream.resultText.trim()
        : "";
    return current === "";
  }

  function itemStreamTail(itemStream, text) {
    if (typeof text !== "string" || text.trim() === "") {
      return "";
    }
    const current = typeof itemStream?.draft === "string" && itemStream.draft.trim() !== ""
      ? itemStream.draft
      : typeof itemStream?.resultText === "string"
        ? itemStream.resultText
        : "";
    if (!current) {
      return text;
    }
    if (text === current) {
      return "";
    }
    if (text.startsWith(current)) {
      return text.slice(current.length);
    }
    return "";
  }

  function isCompletedItemNotification(notification) {
    const method = typeof notification?.method === "string" ? notification.method : "";
    return method === "item/completed" || method === "rawResponseItem/completed";
  }

  async function renderAssistantContentToItemStream(parentStream, notification, text, options = {}) {
    if (deps.isPlainPromptStream && deps.isPlainPromptStream(parentStream)) {
      return undefined;
    }
    if (!deps.shouldRenderAssistantContentInItemStream(notification, deps.enableItemRenderStreams)) {
      return undefined;
    }
    const itemRender = await ensureNotificationItemRender(parentStream, notification);
    if (!itemRender?.itemStream) {
      return undefined;
    }
    const commands = [];
    const normalizedText = typeof text === "string" ? text : "";
    const appendText = options.forceAppend
      ? normalizedText
      : itemStreamTail(itemRender.itemStream, normalizedText);
    const shouldAppend = options.forceAppend
      ? normalizedText.trim() !== ""
      : appendText.trim() !== "" || shouldAppendItemText(itemRender.itemStream, normalizedText);
    if (itemRender.opened) {
      commands.push(openItemStreamCard(parentStream, itemRender.itemStream.streamId));
    }
    if (shouldAppend) {
      await deps.appendStreamDraft(itemRender.itemStream.streamId, appendText, {
        turnId: notification.turnId || itemRender.itemStream.turnId || "",
        lastEvent: notification.method || "codex.notification",
      });
      commands.push(deps.feishuStreamAppendText(itemRender.itemStream.streamId, appendText));
    }
    if (options.finish) {
      await deps.finalizeStreamState(itemRender.itemStream.streamId, {
        turnId: notification.turnId || itemRender.itemStream.turnId || "",
        threadPath: notification.threadPath || itemRender.itemStream.threadPath || "",
        status: "completed",
        resultText: normalizedText || itemRender.itemStream.draft || "",
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      await deps.upsertItemRenderState(parentStream.streamId, itemRender.itemKey, {
        itemId: notification.itemId || itemRender.itemRender?.itemId || "",
        turnId: notification.turnId || itemRender.itemRender?.turnId || "",
        phase: notification.phase || itemRender.itemRender?.phase || "",
        itemStreamId: itemRender.itemStream.streamId,
        status: "finished",
      });
      commands.push(deps.feishuStreamFinish(itemRender.itemStream.streamId));
    } else {
      await deps.upsertItemRenderState(parentStream.streamId, itemRender.itemKey, {
        itemId: notification.itemId || itemRender.itemRender?.itemId || "",
        turnId: notification.turnId || itemRender.itemRender?.turnId || "",
        phase: notification.phase || itemRender.itemRender?.phase || "",
        itemStreamId: itemRender.itemStream.streamId,
        status: "streaming",
      });
    }
    return commands;
  }

  return {
    isCompletedItemNotification,
    renderAssistantContentToItemStream,
  };
}
