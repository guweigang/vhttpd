export function createSessionCommandHandlers(deps) {
  async function handleSettingsCommand(session, text) {
    if (text === "/settings") {
      const settings = await deps.listSettings();
      return {
        handled: true,
        commands: [deps.replyText(session, settings.length ? deps.settingsListText(settings) : deps.settingsEmptyText())],
      };
    }
    const match = text.match(/^\/setting\s+(\S+)\s+(.+)$/);
    if (!match) {
      return {
        handled: false,
        commands: [],
      };
    }
    const name = match[1].trim();
    const value = match[2].trim();
    await deps.upsertSetting(name, value);
    return {
      handled: true,
      commands: [deps.replyText(session, deps.settingUpdatedText(name, value))],
    };
  }

  async function handleThreadsCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    await deps.rememberSelectionScope(session.sessionKey, session.chatId, "thread");
    const threads = await deps.listRecentProjectThreads(state.projectKey, 8);
    return {
      handled: true,
      commands: [deps.replyText(session, deps.threadsListText(state, threads))],
    };
  }

  async function handleNewCommand(session) {
    const state = await deps.ensureChatState(session.sessionKey, session.chatId);
    const parts = (session.text || "").split(/\s+/).filter(Boolean);
    const nextModel = parts.length > 1 ? parts.slice(1).join(" ").trim() : "";
    const next = await deps.updateChatState(session.sessionKey, session.chatId, {
      model: nextModel || state.model,
      threadId: "",
      threadPath: "",
    });
    return {
      handled: true,
      commands: [deps.replyText(session, deps.newConversationText(next, state.threadId || "", state.model || ""))],
    };
  }

  return {
    handleNewCommand,
    handleSettingsCommand,
    handleThreadsCommand,
  };
}
