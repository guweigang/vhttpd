import { parseCodexRpcResponse } from "./codex.mts";

function turnLifecycleText(stage) {
  if (stage === "finalizing") {
    return "### 本轮处理中\n\n正在收尾...";
  }
  if (stage === "completed") {
    return "### 本轮已完成\n\n本轮输出结束。";
  }
  return "### 本轮处理中\n\n处理中...";
}

function updateParentLifecycleCommands(streamId, text, deps = {}, options = {}) {
  if (!streamId || typeof text !== "string" || text.trim() === "") {
    return [];
  }
  const commands = [deps.feishuUpdateText(streamId, text)];
  if (options.finish) {
    commands.push(deps.feishuStreamFinish(streamId));
  }
  return commands;
}

function normalizedThreadReadStatus(result) {
  const status = result?.thread?.status;
  if (typeof status === "string") {
    return status.trim().toLowerCase();
  }
  if (status && typeof status.type === "string") {
    return status.type.trim().toLowerCase();
  }
  return "";
}

function streamTextCommand(stream, streamId, text, deps) {
  if (deps.isPlainPromptStream(stream)) {
    return deps.sendStreamText(stream, text, streamId);
  }
  return deps.feishuUpdateText(streamId, text);
}

function joinPlainPromptAssistantItems(items) {
  if (!Array.isArray(items) || !items.length) {
    return "";
  }
  const blocks = [];
  let sawFinalAnswer = false;
  for (const item of items) {
    const text = typeof item?.text === "string" ? item.text.trim() : "";
    if (!text) {
      continue;
    }
    const phase = typeof item?.phase === "string" ? item.phase.trim() : "";
    if (phase === "commentary" && sawFinalAnswer) {
      continue;
    }
    if (!blocks.includes(text)) {
      blocks.push(text);
    }
    if (phase === "final_answer") {
      sawFinalAnswer = true;
    }
  }
  return blocks.join("\n\n").trim();
}

function recoveredItemNotification(response, stream, item = {}) {
  const preferredTurnId = typeof item?.turnId === "string" && item.turnId.trim() !== ""
    ? item.turnId.trim()
    : (stream?.turnId || response?.turnId || "");
  const preferredThreadId = response?.threadId || stream?.threadId || "";
  const phase = typeof item?.phase === "string" ? item.phase.trim() : "";
  return {
    method: phase === "final_answer" ? "rawResponseItem/completed" : "item/completed",
    streamId: response?.streamId || stream?.streamId || "",
    threadId: preferredThreadId,
    turnId: preferredTurnId,
    itemId: typeof item?.itemId === "string" ? item.itemId.trim() : "",
    itemType: "agentMessage",
    itemRole: "assistant",
    phase,
    threadPath: response?.threadPath || stream?.threadPath || "",
    message: typeof item?.text === "string" ? item.text : "",
    finalText: phase === "final_answer" && typeof item?.text === "string" ? item.text : "",
  };
}

async function finishOutstandingItemStreams(parentStream, keepItemKeys, deps = {}, options = {}) {
  const renders = typeof deps.listItemRenderStates === "function"
    ? await deps.listItemRenderStates(parentStream?.streamId || "")
    : [];
  if (!renders.length) {
    return [];
  }
  const keep = keepItemKeys instanceof Set ? keepItemKeys : new Set(Array.isArray(keepItemKeys) ? keepItemKeys : []);
  const targetTurnId = typeof options.turnId === "string" ? options.turnId.trim() : "";
  const commands = [];
  for (const render of renders) {
    if (!render || render.status === "finished" || !render.itemStreamId) {
      continue;
    }
    if (keep.has(render.itemKey)) {
      continue;
    }
    if (targetTurnId && render.turnId && render.turnId !== targetTurnId) {
      continue;
    }
    const itemStream = await deps.getStreamState(render.itemStreamId);
    if (itemStream) {
      await deps.finalizeStreamState(render.itemStreamId, {
        turnId: render.turnId || itemStream.turnId || targetTurnId,
        threadPath: itemStream.threadPath || parentStream?.threadPath || "",
        status: "completed",
        resultText: itemStream.resultText || itemStream.draft || "",
        completedAt: Date.now(),
        lastEvent: options.lastEvent || "thread/read.recovered_finish",
      });
    }
    await deps.upsertItemRenderState(parentStream.streamId, render.itemKey, {
      itemId: render.itemId || "",
      turnId: render.turnId || targetTurnId,
      phase: render.phase || "",
      itemStreamId: render.itemStreamId,
      status: "finished",
    });
    commands.push(deps.feishuStreamFinish(render.itemStreamId));
  }
  return commands;
}

async function recoverPlainPromptReadItems(stream, response, items, deps = {}) {
  const normalizedItems = Array.isArray(items)
    ? items
      .map((item) => ({
        itemId: typeof item?.itemId === "string" ? item.itemId : "",
        turnId: typeof item?.turnId === "string" ? item.turnId : (stream?.turnId || response?.turnId || ""),
        phase: typeof item?.phase === "string" ? item.phase : "",
        text: typeof item?.text === "string" ? item.text : "",
      }))
      .filter((item) => item.text.trim() !== "")
    : [];
  const commands = [];
  const keepItemKeys = new Set();
  for (const item of normalizedItems) {
    const itemNotification = recoveredItemNotification(response, stream, item);
    const itemKey = deps.notificationItemKey?.(itemNotification);
    if (itemKey) {
      keepItemKeys.add(itemKey);
    }
    const itemCommands = await deps.renderAssistantContentToItemStream(stream, itemNotification, item.text, {
      finish: true,
      allowSyntheticOpen: true,
    });
    if (Array.isArray(itemCommands) && itemCommands.length) {
      commands.push(...itemCommands);
    }
  }
  const finishCommands = await finishOutstandingItemStreams(stream, keepItemKeys, deps, {
    turnId: stream?.turnId || response?.turnId || "",
    lastEvent: "thread/read.recovered_finish",
  });
  if (finishCommands.length) {
    commands.push(...finishCommands);
  }
  return commands;
}

export function createCodexRpcResponseRouter(deps) {
  return async function handleCodexRpcResponse(frame) {
    const response = parseCodexRpcResponse(frame);
    frame.runtime.log(
      "codexbot-app-ts rpc.response",
      deps.buildTag,
      response.method || "",
      response.streamId || "",
      response.hasError ? "error" : "ok",
      response.threadId || "",
    );
    const stream = await deps.getStreamState(response.streamId);
    if (!stream) {
      frame.runtime.warn(
        "codexbot-app-ts rpc.response missing stream",
        deps.buildTag,
        response.method || "",
        response.streamId || "",
        response.errorMessage || "",
      );
      return {
        handled: false,
        commands: [],
      };
    }
    if (response.method === "thread/start" && !response.hasError && response.threadId) {
      const commands = await deps.continueQueuedTurnStart(response.streamId, response.threadId, response.threadPath || "");
      if (!commands.length) {
        await deps.updateStreamState(response.streamId, {
          threadPath: response.threadPath || stream.threadPath || "",
          lastEvent: "thread/start",
        });
      }
      return {
        handled: true,
        commands,
      };
    }
    if (!stream.prompt.startsWith("/codex") && response.hasError && deps.codexRpcIndicatesMissingThread(response)) {
      const recoveredChat = await deps.resetChatThread(stream.sessionKey, stream.chatId);
      await deps.updateStreamState(response.streamId, {
        threadId: "",
        threadPath: "",
        turnId: "",
        status: "queued",
        resultText: "",
        completedAt: 0,
        lastEvent: "thread/restart.requested",
      });
      const defaults = deps.botDefaults();
      const instance = deps.fallbackCodexInstance(stream.codexInstance || recoveredChat?.codexInstance, defaults);
      return {
        handled: true,
        commands: [
          streamTextCommand(stream, response.streamId, deps.threadExpiredRestartingText(stream.threadId || recoveredChat?.threadId || ""), deps),
          deps.codexRpcCall("thread/start", deps.buildThreadStartParams(recoveredChat || stream, defaults), response.streamId, instance),
        ],
      };
    }
    if (response.method === "thread/read" && !stream.prompt.startsWith("/codex")) {
      if (response.hasError) {
        const errorText = deps.codexRpcErrorText(response.method, response.errorMessage || deps.truncateText(deps.prettyJson(response.raw)));
        await deps.finalizeStreamState(response.streamId, {
          status: "error",
          resultText: errorText,
          completedAt: Date.now(),
          lastEvent: response.method || "thread/read",
        });
        return {
          handled: true,
          commands: [streamTextCommand(stream, response.streamId, errorText, deps)],
        };
      }
      const threadName = deps.extractThreadNameFromResult(response.result);
      deps.rememberThreadName(response.threadId || stream.threadId || "", threadName);
      const readThreadStatus = normalizedThreadReadStatus(response.result);
      if (deps.isPlainPromptStream(stream) && readThreadStatus === "active") {
        await deps.updateStreamState(response.streamId, {
          threadPath: response.threadPath || stream.threadPath || "",
          lastEvent: "thread/read",
        });
        return {
          handled: true,
          commands: [],
        };
      }
      const preferredTurnId = stream.turnId || "";
      const readItems = deps.isPlainPromptStream(stream)
        ? deps.extractAssistantItemsFromReadResult(response.result, preferredTurnId)
        : [];
      const exactReadAnswer = preferredTurnId
        ? deps.extractExactAnswerFromThreadReadResult(response.result, preferredTurnId)
        : "";
      if (deps.isPlainPromptStream(stream) && preferredTurnId && !exactReadAnswer && !readItems.length) {
        await deps.updateStreamState(response.streamId, {
          threadPath: response.threadPath || stream.threadPath || "",
          lastEvent: "thread/read",
        });
        return {
          handled: true,
          commands: [],
        };
      }
      const readAnswer = deps.isPlainPromptStream(stream)
        ? (joinPlainPromptAssistantItems(readItems) || exactReadAnswer || deps.extractAnswerFromThreadReadResult(response.result, preferredTurnId))
        : (exactReadAnswer || deps.extractAnswerFromThreadReadResult(response.result, preferredTurnId));
      const resultText = readAnswer || deps.threadReadEmptyText(response.threadId || stream.threadId || "");
      await deps.finalizeStreamState(response.streamId, {
        threadPath: response.threadPath || stream.threadPath || "",
        status: "completed",
        resultText,
        completedAt: Date.now(),
        lastEvent: "thread/read",
      });
      const renderedReadAnswer = readAnswer ? deps.renderCodexAssistantText(readAnswer) : resultText;
      if (deps.isPlainPromptStream(stream)) {
        const recoveredItems = readItems.length
          ? readItems
          : (readAnswer
              ? [{
                  itemId: "",
                  turnId: preferredTurnId,
                  phase: exactReadAnswer ? "final_answer" : "",
                  text: readAnswer,
                }]
              : []);
        const itemCommands = await recoverPlainPromptReadItems(stream, response, recoveredItems, deps);
        return {
          handled: true,
          commands: updateParentLifecycleCommands(response.streamId, turnLifecycleText("completed"), deps, { finish: true })
            .concat(itemCommands || []),
        };
      }
      const readCommands = renderedReadAnswer ? [streamTextCommand(stream, response.streamId, renderedReadAnswer, deps)] : [];
      return {
        handled: true,
        commands: readAnswer ? readCommands : (renderedReadAnswer ? [streamTextCommand(stream, response.streamId, renderedReadAnswer, deps)] : []),
      };
    }
    if (response.method === "thread/name/set" && !stream.prompt.startsWith("/codex")) {
      const renameThreadId = response.threadId || stream.threadId || "";
      if (response.hasError) {
        const pendingRename = deps.consumePendingThreadRename(renameThreadId);
        if (pendingRename?.previousName) {
          deps.rememberThreadName(renameThreadId, pendingRename.previousName);
        } else if (renameThreadId) {
          deps.deleteThreadName(renameThreadId);
        }
        const errorText = deps.codexRpcErrorText(response.method, response.errorMessage || deps.truncateText(deps.prettyJson(response.raw)));
        await deps.finalizeStreamState(response.streamId, {
          status: "error",
          resultText: errorText,
          completedAt: Date.now(),
          lastEvent: response.method || "codex.rpc.response",
        });
        return {
          handled: true,
          commands: [deps.feishuUpdateText(response.streamId, errorText)],
        };
      }
      deps.consumePendingThreadRename(renameThreadId);
      const previousTitle = stream.prompt.replace(/^\/thread\s+rename\s+/i, "").trim();
      const nextTitle = deps.extractThreadNameFromResult(response.result) || previousTitle;
      deps.rememberThreadName(renameThreadId, nextTitle);
      const resultText = deps.threadRenamedText(renameThreadId, previousTitle, nextTitle);
      await deps.finalizeStreamState(response.streamId, {
        status: "completed",
        resultText,
        completedAt: Date.now(),
        lastEvent: response.method || "codex.rpc.response",
      });
      return {
        handled: true,
        commands: [deps.feishuUpdateText(response.streamId, resultText)],
      };
    }
    if (stream.prompt && stream.prompt.startsWith("/codex")) {
      if (response.hasError) {
        const errorText = deps.codexRpcErrorText(response.method, response.errorMessage || deps.truncateText(deps.prettyJson(response.raw)));
        await deps.finalizeStreamState(response.streamId, {
          status: "error",
          resultText: errorText,
          completedAt: Date.now(),
          lastEvent: response.method || "codex.rpc.response",
        });
        return {
          handled: true,
          commands: [deps.feishuUpdateText(response.streamId, errorText)],
        };
      }
      const resultText = deps.formatCodexRpcResult(response.method, response.result, response.raw.result ?? response.raw);
      await deps.finalizeStreamState(response.streamId, {
        status: "completed",
        resultText,
        completedAt: Date.now(),
        lastEvent: response.method || "codex.rpc.response",
      });
      return {
        handled: true,
        commands: [deps.feishuUpdateText(response.streamId, resultText)],
      };
    }
    if (response.method === "turn/start" && !response.hasError) {
      await deps.finalizeStreamState(response.streamId, {
        turnId: response.turnId || stream.turnId || "",
        status: "running",
        lastEvent: "turn/start",
      });
      return {
        handled: true,
        commands: deps.isPlainPromptStream(stream) ? [] : [deps.feishuUpdateText(response.streamId, deps.taskRunningText(stream))],
      };
    }
    if (response.hasError) {
      const diagnosticText = response.errorMessage || deps.truncateText(deps.codexRpcDebugText(response)) || deps.truncateText(deps.prettyJson(response.raw));
      frame.runtime.warn(
        "codexbot-app-ts rpc.response error",
        deps.buildTag,
        response.method || "",
        response.streamId || "",
        diagnosticText,
      );
      const errorText = deps.codexRpcErrorText(response.method, diagnosticText);
      await deps.finalizeStreamState(response.streamId, {
        status: "error",
        resultText: errorText,
        lastEvent: response.method || "codex.rpc.response",
        completedAt: Date.now(),
      });
      return {
        handled: true,
        commands: [streamTextCommand(stream, response.streamId, errorText, deps)],
      };
    }
    return {
      handled: true,
      commands: [],
    };
  };
}
