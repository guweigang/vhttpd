import {
  buildThreadStartParams as defaultBuildThreadStartParams,
  buildTurnStartParams as defaultBuildTurnStartParams,
} from "./codex-start-params.mjs";
import {
  codexRpcCall as defaultCodexRpcCall,
  codexTurnStart as defaultCodexTurnStart,
} from "./commands.mts";

export function createThreadTaskCommandHandlers(deps) {
  const buildThreadStartParams = typeof deps.buildThreadStartParams === "function"
    ? deps.buildThreadStartParams
    : defaultBuildThreadStartParams;
  const buildTurnStartParams = typeof deps.buildTurnStartParams === "function"
    ? deps.buildTurnStartParams
    : defaultBuildTurnStartParams;
  const codexRpcCall = typeof deps.codexRpcCall === "function"
    ? deps.codexRpcCall
    : defaultCodexRpcCall;
  const codexTurnStart = typeof deps.codexTurnStart === "function"
    ? deps.codexTurnStart
    : defaultCodexTurnStart;

  async function handleThreadCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = (session.text || "").split(/\s+/).filter(Boolean);
    if (parts.length > 1) {
      if (parts[1] === "rename") {
        const title = parts.slice(2).join(" ").trim();
        if (!title) {
          return {
            handled: true,
            commands: [deps.replyText(session, deps.usageText("/thread rename", "[title]"))],
          };
        }
        if (!state.threadId) {
          return {
            handled: true,
            commands: [deps.replyText(session, deps.codexThreadRequiredText())],
          };
        }
        const previousName = deps.lookupThreadName(state.threadId);
        deps.rememberPendingThreadRename(state.threadId, previousName, title);
        deps.rememberThreadName(state.threadId, title);
        const project = await deps.getProjectRecord(state.projectKey);
        const stream = await deps.createStreamState(session.sessionKey, session.chatId, session.text || `/thread rename ${title}`);
        const streamWithInstance = await deps.ensureStreamCodexInstance(stream, state, project, deps.codexInstancePolicyDeps);
        await deps.updateStreamState(stream.streamId, {
          threadId: state.threadId,
          threadPath: state.threadPath || "",
          status: "rpc_query",
          lastEvent: "thread/rename.requested",
        });
        const preflight = await deps.buildCodexPreflightCommands(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
        const instance = streamWithInstance.codexInstance || await deps.resolveCodexInstance(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
        return {
          handled: true,
          commands: [
            ...preflight,
            deps.replyText(session, deps.threadRenameQueuedText(state.threadId, title), stream.streamId),
            codexRpcCall("thread/name/set", { threadId: state.threadId, name: title }, stream.streamId, instance),
          ],
        };
      }
      const threadId = parts.slice(1).join(" ").trim();
      const recentThreads = await deps.listRecentProjectThreads(state.projectKey, 32);
      const selected = recentThreads.find((stream) => stream.threadId === threadId);
      const interactions = await deps.listRecentThreadStreams(threadId, 3, {
        sessionKey: state.sessionKey,
        projectKey: state.projectKey,
      });
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        threadId,
        threadPath: selected?.threadPath || "",
      });
      return {
        handled: true,
        commands: [deps.replyText(session, deps.threadSelectedText(next, threadId, selected, interactions))],
      };
    }
    const lastStream = state.lastStreamId ? await deps.getStreamState(state.lastStreamId) : undefined;
    const interactions = state.threadId ? await deps.listRecentThreadStreams(state.threadId, 3, {
      sessionKey: state.sessionKey,
      projectKey: state.projectKey,
    }) : [];
    return {
      handled: true,
      commands: [deps.replyText(session, deps.currentThreadSummaryText(
        state,
        deps.streamMatchesThreadContext(lastStream, state) ? lastStream : undefined,
        interactions,
      ))],
    };
  }

  async function handleUseCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const scope = await deps.getSelectionScope(session.sessionKey);
    const parts = (session.text || "").split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.usageText("/use", deps.useCommandSyntax(scope)))],
      };
    }
    const value = parts.slice(1).join(" ").trim();
    if (scope === "project") {
      const project = (await deps.listBoundChatProjects(session.chatId, 64)).find((item) => item.projectKey === value);
      if (!project) {
        return {
          handled: true,
          commands: [deps.replyText(session, deps.projectNotBoundText(value))],
        };
      }
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        projectKey: value,
        cwd: project.repoPath || deps.resolveProjectCwd(state, value),
        codexInstance: deps.fallbackCodexInstance(
          project.defaultCodexInstance || deps.botDefaults().defaultCodexInstance,
          deps.botDefaults(),
        ),
        threadId: "",
        threadPath: "",
      }, {
        syncProjectDefaults: false,
      });
      return {
        handled: true,
        commands: [deps.replyText(session, deps.projectSelectedText(next))],
      };
    }
    if (scope === "model") {
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        model: value,
        threadId: "",
        threadPath: "",
      });
      return {
        handled: true,
        commands: [deps.replyText(session, deps.modelSelectedText(next))],
      };
    }
    if (scope === "instance") {
      const instance = deps.fallbackCodexInstance(value, deps.botDefaults());
      const persisted = await deps.listInstanceSpecs("codex");
      const knownInstances = Array.from(new Set([
        ...deps.configuredCodexInstanceNames(),
        ...persisted.map((entry) => entry.instance),
      ])).sort();
      if (!knownInstances.includes(instance)) {
        return {
          handled: true,
          commands: [deps.replyText(session, deps.codexInstanceUnknownText(instance, knownInstances))],
        };
      }
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        codexInstance: instance,
      }, {
        syncProjectDefaults: false,
      });
      const project = await deps.getProjectRecord(next.projectKey);
      if (!next.threadId) {
        return {
          handled: true,
          commands: [deps.replyText(session, deps.instanceUseSelectedText(next, state.codexInstance || "", project))],
        };
      }
      const stream = await deps.createStreamState(session.sessionKey, session.chatId, session.text || `/use ${value}`);
      const streamWithInstance = await deps.ensureStreamCodexInstance(stream, next, project, deps.codexInstancePolicyDeps);
      await deps.updateStreamState(stream.streamId, {
        threadId: next.threadId,
        threadPath: next.threadPath || "",
        status: "rpc_query",
        lastEvent: "thread/read.requested",
      });
      const preflight = await deps.buildCodexPreflightCommands(next, streamWithInstance, project, deps.codexInstancePolicyDeps);
      return {
        handled: true,
        commands: [
          ...preflight,
          deps.replyText(session, `${deps.instanceUseSelectedText(next, state.codexInstance || "", project, next.threadId, true)}\n- ${deps.threadReadQueuedText()}`, stream.streamId),
          codexRpcCall("thread/read", { threadId: next.threadId, includeTurns: true }, stream.streamId, instance),
        ],
      };
    }
    if (value === "latest") {
      const latest = await deps.getLatestProjectThread(state.projectKey);
      if (!latest?.threadId) {
        return {
          handled: true,
          commands: [deps.replyText(session, deps.latestThreadMissingText(state))],
        };
      }
      const next = await deps.updateChatState(session.sessionKey, session.chatId, {
        threadId: latest.threadId,
        threadPath: latest.threadPath || "",
      });
      const project = await deps.getProjectRecord(next.projectKey);
      const stream = await deps.createStreamState(session.sessionKey, session.chatId, session.text || "/use latest");
      const streamWithInstance = await deps.ensureStreamCodexInstance(stream, next, project, deps.codexInstancePolicyDeps);
      await deps.updateStreamState(stream.streamId, {
        threadId: latest.threadId,
        threadPath: latest.threadPath || "",
        status: "rpc_query",
        lastEvent: "thread/read.requested",
      });
      const preflight = await deps.buildCodexPreflightCommands(next, streamWithInstance, project, deps.codexInstancePolicyDeps);
      const instance = streamWithInstance.codexInstance || await deps.resolveCodexInstance(next, streamWithInstance, project, deps.codexInstancePolicyDeps);
      return {
        handled: true,
        commands: [
          ...preflight,
          deps.replyText(session, `${deps.threadSelectedText(next, latest.threadId, latest)}\n- ${deps.threadReadQueuedText()}`, stream.streamId),
          codexRpcCall("thread/read", { threadId: latest.threadId, includeTurns: true }, stream.streamId, instance),
        ],
      };
    }
    const recentThreads = await deps.listRecentProjectThreads(state.projectKey, 32);
    const selected = recentThreads.find((stream) => stream.threadId === value);
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      threadId: value,
      threadPath: selected?.threadPath || "",
    });
    const project = await deps.getProjectRecord(next.projectKey);
    const stream = await deps.createStreamState(session.sessionKey, session.chatId, session.text || `/use ${value}`);
    const streamWithInstance = await deps.ensureStreamCodexInstance(stream, next, project, deps.codexInstancePolicyDeps);
    await deps.updateStreamState(stream.streamId, {
      threadId: value,
      threadPath: selected?.threadPath || "",
      status: "rpc_query",
      lastEvent: "thread/read.requested",
    });
    const preflight = await deps.buildCodexPreflightCommands(next, streamWithInstance, project, deps.codexInstancePolicyDeps);
    const instance = streamWithInstance.codexInstance || await deps.resolveCodexInstance(next, streamWithInstance, project, deps.codexInstancePolicyDeps);
    return {
      handled: true,
      commands: [
        ...preflight,
        deps.replyText(session, `${deps.threadSelectedText(next, value, selected)}\n- ${deps.threadReadQueuedText()}`, stream.streamId),
        codexRpcCall("thread/read", { threadId: value, includeTurns: true }, stream.streamId, instance),
      ],
    };
  }

  async function handleCancelCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    let lastStream = state.lastStreamId ? await deps.getStreamState(state.lastStreamId) : undefined;
    if (lastStream && deps.isStaleBusyStream(lastStream, deps.activeStreamStaleMs)) {
      lastStream = await deps.detachStaleActiveStream(session, lastStream);
    }
    const instance = deps.fallbackCodexInstance(lastStream?.codexInstance || state.codexInstance, deps.botDefaults());
    if (!lastStream || !deps.isBusyStream(lastStream)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.cancelIdleText(session.sessionKey))],
      };
    }
    if (lastStream.threadId && lastStream.turnId) {
      const interruptingText = deps.cancelInterruptingText(lastStream);
      await deps.finalizeStreamState(lastStream.streamId, {
        status: "cancelled",
        resultText: interruptingText,
        completedAt: Date.now(),
        lastEvent: "user.cancel.interrupt",
      });
      await deps.resetChatThread(session.sessionKey, session.chatId);
      return {
        handled: true,
        commands: [
          deps.feishuUpdateText(lastStream.streamId, interruptingText),
          deps.codexTurnInterrupt(lastStream.threadId, lastStream.turnId, lastStream.streamId, instance),
          deps.feishuSessionClear(lastStream.streamId),
          deps.codexSessionClear(lastStream.streamId, lastStream.threadId, instance),
        ],
      };
    }
    const detachedText = deps.cancelDetachedText(lastStream);
    await deps.finalizeStreamState(lastStream.streamId, {
      status: "cancelled",
      resultText: detachedText,
      completedAt: Date.now(),
      lastEvent: "user.cancel",
    });
    await deps.resetChatThread(session.sessionKey, session.chatId);
    return {
      handled: true,
      commands: [
        deps.feishuUpdateText(lastStream.streamId, detachedText),
        deps.feishuSessionClear(lastStream.streamId),
        deps.codexSessionClear(lastStream.streamId, state.threadId || lastStream.threadId || "", instance),
      ],
    };
  }

  async function handleRegularTask(session, prompt) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    let lastStream = state.lastStreamId ? await deps.getStreamState(state.lastStreamId) : undefined;
    if (lastStream && deps.isStaleBusyStream(lastStream, deps.activeStreamStaleMs)) {
      lastStream = await deps.detachStaleActiveStream(session, lastStream);
    }
    if (lastStream && deps.isBusyStream(lastStream)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.busyText(lastStream))],
      };
    }
    const project = await deps.getProjectRecord(state.projectKey);
    const stream = await deps.createStreamState(session.sessionKey, session.chatId, prompt);
    const streamWithInstance = await deps.ensureStreamCodexInstance(stream, state, project, deps.codexInstancePolicyDeps);
    const defaults = deps.botDefaults();
    const preflight = await deps.buildCodexPreflightCommands(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
    const instance = streamWithInstance.codexInstance || await deps.resolveCodexInstance(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
    const commands = [...preflight];
    if (state.threadId) {
      commands.push(codexTurnStart(buildTurnStartParams(streamWithInstance, state, defaults), stream.streamId, instance));
    } else {
      commands.push(codexRpcCall("thread/start", buildThreadStartParams(state, defaults), stream.streamId, instance));
    }
    return {
      handled: true,
      commands,
    };
  }

  return {
    handleCancelCommand,
    handleRegularTask,
    handleThreadCommand,
    handleUseCommand,
  };
}
