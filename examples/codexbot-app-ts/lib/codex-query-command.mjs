export function createCodexQueryCommandHandler(deps) {
  return async function handleCodexCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parsed = deps.parseCodexCommand(session.text || "");
    if (!parsed.method) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.codexCommandHelpText(state))],
      };
    }
    if (parsed.error) {
      return {
        handled: true,
        commands: [deps.replyText(session, `${parsed.error}\n\n${deps.codexCommandHelpText(state)}`)],
      };
    }
    const normalized = deps.normalizeCodexAlias(parsed.method, parsed.params, state);
    if (!deps.codeQueryMethods.has(normalized.method)) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.unsupportedCodexMethodText(parsed.method))],
      };
    }
    const baseParams = deps.defaultCodexParams(normalized.method, state);
    const params = normalized.params ? { ...(baseParams || {}), ...normalized.params } : (baseParams || {});
    if (normalized.method === "thread/read" && !params.threadId) {
      return {
        handled: true,
        commands: [deps.replyText(session, deps.codexThreadRequiredText())],
      };
    }
    const stream = await deps.createStreamState(session.sessionKey, session.chatId, session.text || `/codex ${parsed.method}`);
    const project = await deps.getProjectRecord(state.projectKey);
    const streamWithInstance = await deps.ensureStreamCodexInstance(stream, state, project, deps.codexInstancePolicyDeps);
    await deps.updateStreamState(stream.streamId, {
      status: "rpc_query",
      lastEvent: `codex.rpc.query.${normalized.method}`,
    });
    const preflight = await deps.buildCodexPreflightCommands(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
    const instance = streamWithInstance.codexInstance || await deps.resolveCodexInstance(state, streamWithInstance, project, deps.codexInstancePolicyDeps);
    return {
      handled: true,
      commands: [
        ...preflight,
        deps.replyText(session, deps.codexRpcQueuedText(normalized.method), stream.streamId),
        deps.codexRpcCall(normalized.method, params, stream.streamId, instance),
      ],
    };
  };
}
