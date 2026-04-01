import { parseCodexRpcResponse } from "./codex.mts";

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

function streamTail(currentText, nextText) {
  const current = typeof currentText === "string" ? currentText : "";
  const next = typeof nextText === "string" ? nextText : "";
  if (!next) {
    return "";
  }
  if (!current) {
    return next;
  }
  if (next === current) {
    return "";
  }
  if (next.startsWith(current)) {
    return next.slice(current.length);
  }
  return "";
}

function plainPromptParentTextCommands(stream, streamId, text, deps, options = {}) {
  const nextText = typeof text === "string" ? text : "";
  if (!nextText.trim()) {
    return [];
  }
  const currentText = typeof stream?.draft === "string" && stream.draft !== ""
    ? stream.draft
    : (typeof stream?.resultText === "string" ? stream.resultText : "");
  const tail = streamTail(currentText, nextText);
  const commands = [];
  if (!currentText) {
    commands.push(deps.openParentStreamCard(stream, streamId));
    commands.push(deps.feishuStreamAppendText(streamId, nextText));
  } else if (tail) {
    commands.push(deps.feishuStreamAppendText(streamId, tail));
  } else if (nextText !== currentText) {
    commands.push(deps.feishuUpdateText(streamId, deps.renderCodexAssistantText(nextText)));
  }
  if (options.finish && streamId && commands[commands.length - 1]?.type !== "provider.message.update") {
    commands.push(deps.feishuStreamFinish(streamId));
  }
  return commands;
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
      if (deps.isPlainPromptStream(stream) && preferredTurnId && !exactReadAnswer) {
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
      const readCommands = deps.isPlainPromptStream(stream)
        ? plainPromptParentTextCommands(stream, response.streamId, readAnswer || "", deps, { finish: true })
        : (renderedReadAnswer ? [streamTextCommand(stream, response.streamId, renderedReadAnswer, deps)] : []);
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
