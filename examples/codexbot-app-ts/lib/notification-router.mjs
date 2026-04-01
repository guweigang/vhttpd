import { parseCodexNotification } from "./codex.mts";
import { normalizeCodexRuntimeStatus } from "../codex/protocol.mts";

function streamTextCommand(stream, streamId, text, deps) {
  if (deps.isPlainPromptStream(stream)) {
    return deps.sendStreamText(stream, text, streamId);
  }
  return deps.feishuUpdateText(streamId, text);
}

function resolveSessionPath(runtime, stream, latest) {
  const explicitPath = latest?.threadPath || stream.threadPath || "";
  if (explicitPath) {
    return explicitPath;
  }
  const threadId = latest?.threadId || stream.threadId || "";
  if (!threadId || !runtime || typeof runtime.findCodexSessionPath !== "function") {
    return "";
  }
  try {
    return runtime.findCodexSessionPath(threadId, "");
  } catch (_) {
    return "";
  }
}

function logCodexRoute(runtime, stage, options = {}, deps = {}) {
  if (!runtime || typeof runtime.log !== "function") {
    return;
  }
  const instance = deps.fallbackCodexInstance ? deps.fallbackCodexInstance(options.instance || "", deps.botDefaults()) : (options.instance || "");
  const spec = deps.buildCodexInstanceSpec
    ? deps.buildCodexInstanceSpec(options.state, options.stream, deps.botDefaults(), instance)
    : {};
  runtime.log(
    "codexbot-app-ts codex route",
    deps.buildTag || "",
    stage,
    `instance=${instance}`,
    `url=${spec?.url || ""}`,
    `threadId=${options.threadId || ""}`,
    `sessionPath=${options.sessionPath || ""}`,
    `streamId=${options.streamId || ""}`,
  );
}

async function persistNotificationContext(streamId, notification, stream, deps = {}) {
  const patch = {};
  if (notification.turnId && notification.turnId !== stream.turnId) {
    patch.turnId = notification.turnId;
  }
  if (notification.threadId && notification.threadId !== stream.threadId) {
    patch.threadId = notification.threadId;
  }
  if (notification.threadPath && notification.threadPath !== stream.threadPath) {
    patch.threadPath = notification.threadPath;
  }
  if (notification.method) {
    patch.lastEvent = notification.method;
  }
  return Object.keys(patch).length > 0 && deps.updateStreamState
    ? deps.updateStreamState(streamId, patch)
    : stream;
}

function streamedFinalTail(stream, finalText) {
  const nextText = typeof finalText === "string" ? finalText : "";
  if (!nextText) {
    return "";
  }
  const currentDraft = typeof stream?.draft === "string" ? stream.draft : "";
  if (!currentDraft) {
    return nextText;
  }
  if (nextText === currentDraft) {
    return "";
  }
  if (nextText.startsWith(currentDraft)) {
    return nextText.slice(currentDraft.length);
  }
  return "";
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

function parentStreamTextCommands(stream, streamId, text, deps = {}, options = {}) {
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

function mergePlainPromptBlocks(currentText, nextText) {
  const current = typeof currentText === "string" ? currentText.trim() : "";
  const next = typeof nextText === "string" ? nextText.trim() : "";
  if (!next) {
    return current;
  }
  if (!current) {
    return next;
  }
  if (next === current || current.includes(next)) {
    return current;
  }
  if (next.startsWith(current)) {
    return next;
  }
  return `${current}\n\n${next}`.trim();
}

function finishParentStreamCommands(stream, finalText, deps = {}) {
  if (!stream?.streamId || typeof finalText !== "string" || finalText.trim() === "") {
    return [];
  }
  const commands = [];
  const tail = streamedFinalTail(stream, finalText);
  if (tail) {
    commands.push(deps.feishuStreamAppendText(stream.streamId, tail));
  }
  commands.push(deps.feishuStreamFinish(stream.streamId));
  return commands;
}

function shouldFinalizeParentFromFinalText(notification) {
  const method = typeof notification?.method === "string" ? notification.method : "";
  const phase = typeof notification?.phase === "string" ? notification.phase : "";
  const finalText = typeof notification?.finalText === "string" ? notification.finalText.trim() : "";
  const itemType = typeof notification?.itemType === "string" ? notification.itemType.trim() : "";
  const itemRole = typeof notification?.itemRole === "string" ? notification.itemRole.trim() : "";
  if (method === "turn/completed" || phase === "final_answer") {
    return true;
  }
  if (method === "rawResponseItem/completed" && finalText) {
    return true;
  }
  if (method === "item/completed" && finalText && !itemType && !itemRole) {
    return true;
  }
  return false;
}

function shouldReadThreadOnIdle(latest, stream, settledText = "") {
  const current = latest || stream || {};
  const lookupThreadId = current.threadId || "";
  if (!lookupThreadId) {
    return false;
  }
  const status = typeof current.status === "string" ? current.status.trim() : "";
  const lastEvent = typeof current.lastEvent === "string" ? current.lastEvent.trim() : "";
  if (status === "reading_final" || lastEvent === "thread/read") {
    return false;
  }
  if (status === "completed" && settledText) {
    return false;
  }
  if (lastEvent === "turn/completed" || lastEvent === "rawResponseItem/completed") {
    return false;
  }
  return true;
}

function preferredIdleText(settledText, sessionAnswer) {
  const current = typeof settledText === "string" ? settledText.trim() : "";
  const session = typeof sessionAnswer === "string" ? sessionAnswer.trim() : "";
  if (!session) {
    return current;
  }
  if (!current) {
    return session;
  }
  if (session === current) {
    return current;
  }
  if (session.length > current.length) {
    return session;
  }
  return current;
}

export async function routeCodexNotification(frame, deps) {
  const notification = parseCodexNotification(frame);
  frame.runtime.log("codexbot-app-ts notification", deps.buildTag, notification.method, notification.status || "", notification.threadId || "", notification.streamId || "");
  let stream = await deps.getStreamState(notification.streamId);
  if (!stream) {
    frame.runtime.warn("codexbot-app-ts notification missing stream", deps.buildTag, notification.streamId || "");
    return {
      handled: false,
      commands: [],
    };
  }
  if (notification.threadId) {
    const nextThreadPath = notification.threadPath || stream.threadPath || "";
    if (notification.threadId !== stream.threadId || nextThreadPath !== (stream.threadPath || "")) {
      await deps.bindThreadToStream(notification.streamId, notification.threadId, nextThreadPath);
      stream = (await deps.getStreamState(notification.streamId)) || stream;
    }
  }
  stream = (await persistNotificationContext(notification.streamId, notification, stream, deps)) || stream;
  if (notification.method === "thread/status/changed" && deps.isTerminalIdleStatus(notification.status || "")) {
    const latest = await deps.getStreamState(notification.streamId);
    const isPlainPrompt = deps.isPlainPromptStream(latest || stream);
    const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
    const preferredTurnId = notification.turnId || latest?.turnId || stream.turnId || "";
    const sessionAnswer = deps.readFinalAnswerFromSessionPath(frame.runtime, resolvedSessionPath, preferredTurnId);
    const settledText = notification.finalText || notification.message || latest?.resultText || latest?.draft || stream.resultText || stream.draft || "";
    const preferredText = preferredIdleText(settledText, sessionAnswer);
    const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
    const shouldReadFinal = shouldReadThreadOnIdle(latest, stream, settledText);
    frame.runtime.log(
      "codexbot-app-ts idle check",
      deps.buildTag,
      "stream=" + (notification.streamId || ""),
      "latestStatus=" + (latest?.status || ""),
      "latestLastEvent=" + (latest?.lastEvent || ""),
      "latestDraftLen=" + String((latest?.draft || "").length),
      "latestResultLen=" + String((latest?.resultText || "").length),
      "sessionAnswerLen=" + String(sessionAnswer.length),
      "preferredTextLen=" + String(preferredText.length),
      "shouldReadFinal=" + String(shouldReadFinal),
      "lookupThreadId=" + lookupThreadId,
      "resolvedSessionPath=" + resolvedSessionPath,
    );
    if (!shouldReadFinal && preferredText && preferredText !== settledText) {
      await deps.finalizeStreamState(notification.streamId, {
        turnId: preferredTurnId,
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "completed",
        resultText: preferredText,
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      const parentCommands = isPlainPrompt
        ? parentStreamTextCommands(latest || stream, notification.streamId, preferredText, deps, { finish: true })
        : [deps.feishuUpdateText(notification.streamId, deps.renderCodexAssistantText(preferredText))];
      return {
        handled: true,
        commands: parentCommands,
      };
    }
    if (isPlainPrompt && preferredText && preferredText !== settledText) {
      await deps.finalizeStreamState(notification.streamId, {
        turnId: preferredTurnId,
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "completed",
        resultText: preferredText,
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      return {
        handled: true,
        commands: parentStreamTextCommands(latest || stream, notification.streamId, preferredText, deps, { finish: true }),
      };
    }
    if (shouldReadFinal && lookupThreadId) {
      const instance = deps.fallbackCodexInstance(latest?.codexInstance || stream.codexInstance, deps.botDefaults());
      logCodexRoute(frame.runtime, "thread/read.idle_fallback", {
        state: latest,
        stream,
        instance,
        threadId: lookupThreadId,
        sessionPath: resolvedSessionPath,
        streamId: notification.streamId || "",
      }, deps);
      frame.runtime.log("codexbot-app-ts idle -> thread/read", deps.buildTag, lookupThreadId, notification.streamId || "");
      await deps.updateStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "reading_final",
        lastEvent: notification.method,
      });
      return {
        handled: true,
        commands: deps.isPlainPromptStream(latest || stream)
          ? [deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance)]
          : [
              deps.feishuUpdateText(notification.streamId, deps.codexFinalizingText()),
              deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance),
            ],
      };
    }
    frame.runtime.log("codexbot-app-ts idle -> no-op", deps.buildTag, "settledTextLen=" + String(settledText.length), "lookupThreadId=" + lookupThreadId);
  }
    if (notification.method === "thread/started" && notification.threadId) {
      const commands = await deps.continueQueuedTurnStart(notification.streamId, notification.threadId, notification.threadPath || stream.threadPath || "");
      if (!commands.length) {
        await deps.updateStreamState(notification.streamId, {
          threadPath: notification.threadPath || stream.threadPath || "",
          lastEvent: "thread/started",
        });
      }
      return {
        handled: true,
        commands,
      };
    }
    if (notification.method === "turn/started") {
      await deps.finalizeStreamState(notification.streamId, {
        turnId: notification.turnId || stream.turnId || "",
        status: "running",
        lastEvent: "turn/started",
      });
      return {
        handled: true,
        commands: [],
      };
    }
    if (notification.method === "thread/status/changed" && notification.threadStatusType === "active") {
      return {
        handled: true,
        commands: deps.isPlainPromptStream(stream) && !(stream.draft || stream.resultText)
          ? []
          : (notification.activeFlags?.length ? [deps.feishuUpdateText(notification.streamId, deps.codexActiveStatusText(notification.activeFlags))] : []),
      };
    }
    if (notification.method === "thread/status/changed" && notification.threadStatusType === "systemError") {
      const errorText = deps.codexSystemErrorText(notification);
      await deps.finalizeStreamState(notification.streamId, {
        turnId: notification.turnId || stream.turnId || "",
        threadPath: notification.threadPath || stream.threadPath || "",
        status: "error",
        resultText: errorText,
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      return {
        handled: true,
        commands: [streamTextCommand(stream, notification.streamId, errorText, deps)],
      };
    }
    if (notification.delta) {
      const next = await deps.appendStreamDraft(notification.streamId, notification.delta, {
        turnId: notification.turnId || stream.turnId || "",
        lastEvent: notification.method || "item/agentMessage/delta",
      });
      const latestDraft = next ? next.draft : notification.delta;
      frame.runtime.log(
        "codexbot-app-ts stream.append",
        deps.buildTag,
        notification.streamId || "",
        "deltaLen=" + String(notification.delta.length),
        "draftLen=" + String((latestDraft || "").length),
      );
      if (deps.isPlainPromptStream(next || stream)) {
        return {
          handled: true,
          commands: parentStreamTextCommands(stream, notification.streamId, latestDraft, deps),
        };
      }
      const itemCommands = await deps.renderAssistantContentToItemStream(stream, notification, notification.delta, {
        forceAppend: true,
        finish: false,
      });
      if (itemCommands) {
        return {
          handled: true,
          commands: itemCommands,
        };
      }
      return {
        handled: true,
        commands: notification.delta ? [deps.feishuStreamAppendText(notification.streamId, notification.delta)] : [],
      };
    }
    if (notification.finalText) {
      const shouldFinalizeParent = shouldFinalizeParentFromFinalText(notification);
      const isPlainPrompt = deps.isPlainPromptStream(stream);
      const mergedFinalText = isPlainPrompt
        ? mergePlainPromptBlocks(stream.draft || stream.resultText || "", notification.finalText)
        : notification.finalText;
      if (shouldFinalizeParent) {
        await deps.finalizeStreamState(notification.streamId, {
          turnId: notification.turnId || stream.turnId || "",
          threadPath: notification.threadPath || stream.threadPath || "",
          status: "completed",
          draft: mergedFinalText,
          resultText: mergedFinalText,
          completedAt: Date.now(),
          lastEvent: notification.method || "codex.notification",
        });
      }
      const itemCommands = await deps.renderAssistantContentToItemStream(stream, notification, mergedFinalText, {
        finish: true,
      });
      const parentCommands = shouldFinalizeParent
        ? (isPlainPrompt
            ? parentStreamTextCommands(stream, notification.streamId, mergedFinalText, deps, { finish: true })
            : finishParentStreamCommands(stream, deps.renderCodexAssistantText(mergedFinalText), deps))
        : [];
      if (itemCommands) {
        return {
          handled: true,
          commands: parentCommands.concat(itemCommands),
        };
      }
      if (!shouldFinalizeParent) {
        return {
          handled: true,
          commands: [],
        };
      }
      return {
        handled: true,
        commands: parentCommands,
      };
    }
    if (notification.method === "error" || notification.turnStatus === "failed" || (notification.errorMessage && notification.status === "error")) {
      const errorText = deps.codexStructuredErrorText(notification);
      await deps.finalizeStreamState(notification.streamId, {
        turnId: notification.turnId || stream.turnId || "",
        status: "error",
        resultText: errorText,
        completedAt: Date.now(),
        lastEvent: notification.method || "codex.notification",
      });
      return {
        handled: true,
        commands: [streamTextCommand(stream, notification.streamId, errorText, deps)],
      };
    }
    if (notification.message && notification.method !== "turn/completed") {
      const latest = await deps.getStreamState(notification.streamId);
      if ((latest?.status === "completed" || latest?.resultText) && notification.phase === "commentary") {
        const commentaryItemCommands = await deps.renderAssistantContentToItemStream(latest || stream, notification, notification.message, {
          finish: deps.isCompletedItemNotification(notification),
        });
        if (commentaryItemCommands) {
          return {
            handled: true,
            commands: commentaryItemCommands,
          };
        }
        return {
          handled: true,
          commands: [],
        };
      }
      if (deps.isPlainPromptStream(latest || stream)) {
        const mergedMessage = mergePlainPromptBlocks(latest?.draft || latest?.resultText || stream.draft || stream.resultText || "", notification.message);
        if (!mergedMessage) {
          return {
            handled: true,
            commands: [],
          };
        }
        await deps.updateStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          draft: mergedMessage,
          status: "streaming",
          lastEvent: notification.method || "codex.notification",
        });
        return {
          handled: true,
          commands: parentStreamTextCommands(latest || stream, notification.streamId, mergedMessage, deps),
        };
      }
      const itemCommands = await deps.renderAssistantContentToItemStream(stream, notification, notification.message, {
        finish: deps.isCompletedItemNotification(notification),
      });
      if (itemCommands) {
        return {
          handled: true,
          commands: itemCommands,
        };
      }
      await deps.updateStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        status: "streaming",
        lastEvent: notification.method || "codex.notification",
      });
      const renderedMessage = deps.renderCodexAssistantText(notification.message);
      return {
        handled: true,
        commands: renderedMessage ? [streamTextCommand(stream, notification.streamId, renderedMessage, deps)] : [],
      };
    }
    if (notification.method === "turn/completed") {
      const latest = await deps.getStreamState(notification.streamId);
      const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
      const completedText = notification.finalText || notification.message || latest?.resultText || latest?.draft || "";
      const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
      if (!completedText && lookupThreadId) {
        if (deps.isPlainPromptStream(latest || stream)) {
          const existingPlainText = latest?.resultText || latest?.draft || stream.resultText || stream.draft || "";
          await deps.finalizeStreamState(notification.streamId, {
            turnId: notification.turnId || latest?.turnId || stream.turnId || "",
            threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
            status: "completed",
            draft: existingPlainText,
            resultText: existingPlainText,
            completedAt: existingPlainText ? Date.now() : 0,
            lastEvent: "turn/completed",
          });
          return {
            handled: true,
            commands: existingPlainText
              ? parentStreamTextCommands(latest || stream, notification.streamId, existingPlainText, deps, { finish: true })
              : [],
          };
        }
        const instance = deps.fallbackCodexInstance(latest?.codexInstance || stream.codexInstance, deps.botDefaults());
        logCodexRoute(frame.runtime, "thread/read.turn_completed_fallback", {
          state: latest,
          stream,
          instance,
          threadId: lookupThreadId,
          sessionPath: resolvedSessionPath,
          streamId: notification.streamId || "",
        }, deps);
        await deps.updateStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: "reading_final",
          lastEvent: "turn/completed",
        });
        return {
          handled: true,
          commands: deps.isPlainPromptStream(latest || stream)
            ? [deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance)]
            : [
                deps.feishuUpdateText(notification.streamId, deps.codexFinalizingText()),
                deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance),
              ],
        };
      }
      const finalCompletedText = completedText || "Completed.";
      const parentCompletedText = deps.isPlainPromptStream(latest || stream)
        ? mergePlainPromptBlocks(latest?.draft || latest?.resultText || stream.draft || stream.resultText || "", finalCompletedText)
        : finalCompletedText;
      await deps.finalizeStreamState(notification.streamId, {
        turnId: notification.turnId || latest?.turnId || stream.turnId || "",
        threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
        status: "completed",
        draft: parentCompletedText,
        resultText: parentCompletedText,
        completedAt: Date.now(),
        lastEvent: "turn/completed",
      });
      const itemCommands = await deps.renderAssistantContentToItemStream(latest || stream, notification, parentCompletedText, {
        finish: true,
      });
      const parentCommands = deps.isPlainPromptStream(latest || stream)
        ? parentStreamTextCommands(latest || stream, notification.streamId, parentCompletedText, deps, { finish: true })
        : finishParentStreamCommands(latest || stream, deps.renderCodexAssistantText(parentCompletedText), deps);
      if (itemCommands) {
        return {
          handled: true,
          commands: parentCommands.concat(itemCommands),
        };
      }
      return {
        handled: true,
        commands: parentCommands,
      };
    }
    if (notification.status) {
      const latest = await deps.getStreamState(notification.streamId);
      const isPlainPrompt = deps.isPlainPromptStream(latest || stream);
      const resolvedSessionPath = resolveSessionPath(frame.runtime, stream, latest);
      const normalizedStatus = normalizeCodexRuntimeStatus(notification.status);
      if (resolvedSessionPath && !latest?.threadPath && (latest?.threadId || stream.threadId)) {
        await deps.bindThreadToStream(notification.streamId, latest?.threadId || stream.threadId, resolvedSessionPath);
      }
      const settledText = notification.finalText || notification.message || latest?.resultText || latest?.draft || stream.resultText || stream.draft || "";
      const preferredTurnId = notification.turnId || latest?.turnId || stream.turnId || "";
      const preferredText = preferredIdleText(settledText, deps.readFinalAnswerFromSessionPath(frame.runtime, resolvedSessionPath, preferredTurnId));
      const shouldReadFinal = shouldReadThreadOnIdle(latest, stream, settledText);
      const alreadyFinalized = deps.isTerminalStreamStatus(latest?.status || stream.status)
        || (Number(latest?.completedAt || stream.completedAt || 0) > 0 && preferredText !== "");
      if (alreadyFinalized && normalizedStatus && normalizedStatus !== "error" && !deps.isTerminalIdleStatus(notification.status)) {
        return {
          handled: true,
          commands: [],
        };
      }
      if (deps.isTerminalIdleStatus(notification.status) && shouldReadFinal && !isPlainPrompt) {
        const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
        const instance = deps.fallbackCodexInstance(latest?.codexInstance || stream.codexInstance, deps.botDefaults());
        logCodexRoute(frame.runtime, "thread/read.status_fallback", {
          state: latest,
          stream,
          instance,
          threadId: lookupThreadId,
          sessionPath: resolvedSessionPath,
          streamId: notification.streamId || "",
        }, deps);
        await deps.updateStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: "reading_final",
          lastEvent: notification.method || "codex.notification",
        });
        return {
          handled: true,
          commands: deps.isPlainPromptStream(latest || stream)
            ? [deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance)]
            : [
                deps.feishuUpdateText(notification.streamId, deps.codexFinalizingText()),
                deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance),
            ],
        };
      }
      if (
        deps.isTerminalIdleStatus(notification.status)
        && isPlainPrompt
        && (latest?.status || stream.status) === "completed"
        && (latest?.resultText || latest?.draft || stream.resultText || stream.draft || "") === preferredText
      ) {
        return {
          handled: true,
          commands: [],
        };
      }
      if (deps.isTerminalIdleStatus(notification.status) && preferredText) {
        await deps.finalizeStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: "completed",
          draft: preferredText,
          resultText: preferredText,
          completedAt: Date.now(),
          lastEvent: notification.method || "codex.notification",
        });
        const renderedSettled = deps.renderCodexAssistantText(preferredText);
        const parentCommands = isPlainPrompt
          ? parentStreamTextCommands(latest || stream, notification.streamId, preferredText, deps, { finish: true })
          : (preferredText !== settledText
              ? [deps.feishuUpdateText(notification.streamId, renderedSettled)]
              : finishParentStreamCommands(latest || stream, renderedSettled, deps));
        return {
          handled: true,
          commands: !renderedSettled ? [] : parentCommands,
        };
      }
      if (deps.isTerminalIdleStatus(notification.status) && !settledText && !isPlainPrompt) {
        const lookupThreadId = latest?.threadId || stream.threadId || notification.threadId || "";
        if (lookupThreadId) {
          const instance = deps.fallbackCodexInstance(latest?.codexInstance || stream.codexInstance, deps.botDefaults());
          logCodexRoute(frame.runtime, "thread/read.status_fallback", {
            state: latest,
            stream,
            instance,
            threadId: lookupThreadId,
            sessionPath: resolvedSessionPath,
            streamId: notification.streamId || "",
          }, deps);
          await deps.updateStreamState(notification.streamId, {
            turnId: notification.turnId || latest?.turnId || stream.turnId || "",
            threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
            status: "reading_final",
            lastEvent: notification.method || "codex.notification",
          });
          return {
            handled: true,
            commands: deps.isPlainPromptStream(latest || stream)
              ? [deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance)]
              : [
                  deps.feishuUpdateText(notification.streamId, deps.codexFinalizingText()),
                  deps.codexRpcCall("thread/read", { threadId: lookupThreadId, includeTurns: true }, notification.streamId, instance),
                ],
          };
        }
      }
      if (deps.isTerminalIdleStatus(notification.status) && isPlainPrompt && !preferredText) {
        await deps.finalizeStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: normalizedStatus,
          resultText: latest?.resultText || stream.resultText || "",
          lastEvent: notification.method || "codex.notification",
          completedAt: 0,
        });
        return {
          handled: true,
          commands: [],
        };
      }
      if (normalizedStatus !== "active" && normalizedStatus !== "systemerror") {
        await deps.finalizeStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: normalizedStatus,
          resultText: latest?.resultText || stream.resultText || "",
          lastEvent: notification.method || "codex.notification",
          completedAt: normalizedStatus === "completed" ? Date.now() : 0,
        });
      } else {
        await deps.updateStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          lastEvent: notification.method || "codex.notification",
        });
      }
      if (normalizedStatus === "running" && !notification.message) {
        return {
          handled: true,
          commands: [],
        };
      }
      if (normalizedStatus === "active") {
        return {
          handled: true,
          commands: deps.isPlainPromptStream(latest || stream) && !settledText
            ? []
            : (notification.activeFlags?.length ? [deps.feishuUpdateText(notification.streamId, deps.codexActiveStatusText(notification.activeFlags))] : []),
        };
      }
      if (normalizedStatus === "systemerror") {
        const errorText = deps.codexSystemErrorText(notification);
        await deps.finalizeStreamState(notification.streamId, {
          turnId: notification.turnId || latest?.turnId || stream.turnId || "",
          threadPath: resolvedSessionPath || latest?.threadPath || stream.threadPath || "",
          status: "error",
          resultText: errorText,
          lastEvent: notification.method || "codex.notification",
          completedAt: Date.now(),
        });
        return {
          handled: true,
          commands: [streamTextCommand(latest || stream, notification.streamId, errorText, deps)],
        };
      }
      return {
        handled: true,
        commands: settledText && !notification.message
          ? []
          : [streamTextCommand(latest || stream, notification.streamId, deps.codexStatusText(normalizedStatus, notification.message || ""), deps)],
      };
    }
  return {
    handled: true,
    commands: [],
  };
}

export function createCodexNotificationRouter(deps) {
  return function handleCodexNotification(frame) {
    return routeCodexNotification(frame, deps);
  };
}
