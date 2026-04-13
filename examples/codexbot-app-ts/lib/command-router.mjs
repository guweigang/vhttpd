import { parseFeishuInboundFrame } from "./feishu.mts";

function isSelfFeishuInbound(inbound) {
  const senderType = typeof inbound?.senderType === "string" ? inbound.senderType.trim().toLowerCase() : "";
  return senderType === "app" || senderType === "bot";
}

export function createFeishuCommandRouter(deps) {
  return async function routeFeishuCommand(frame) {
    const inbound = parseFeishuInboundFrame(frame);
    if (inbound.eventType === "card.action.trigger" || inbound.eventKind === "action") {
      return deps.handleApprovalAction(inbound, frame);
    }
    if (inbound.chatId === "" || inbound.text === "") {
      return {
        handled: false,
        commands: [],
      };
    }
    if (isSelfFeishuInbound(inbound)) {
      frame.runtime.log("codexbot-app-ts inbound ignored self", deps.buildTag, inbound.messageId || "", inbound.senderType || "");
      return {
        handled: true,
        commands: [],
      };
    }
    if (await deps.shouldIgnoreInbound(inbound)) {
      frame.runtime.log("codexbot-app-ts inbound deduped", deps.buildTag, inbound.messageId || "", inbound.chatId || "");
      return {
        handled: true,
        commands: [],
      };
    }
    const text = inbound.text;
    const session = {
      chatId: inbound.chatId,
      sessionKey: inbound.sessionKey || inbound.chatId,
      replyTarget: inbound.replyTarget || inbound.chatId,
      replyTargetType: inbound.replyTargetType || "chat_id",
      text,
    };
    if (!deps.isUseCommandText(text)) {
      await deps.clearSelectionScope(session.sessionKey);
    }
    if (text === "/help" || text === "help" || text === "帮助") {
      return deps.handleHelp(session);
    }
    if (text === "/codex" || text.startsWith("/codex ")) {
      return deps.handleCodexCommand(session);
    }
    if (text === "/settings" || text === "/setting" || text.startsWith("/setting ")) {
      return deps.handleSettingsCommand(session, text);
    }
    if (text === "/instances") {
      return deps.handleInstancesCommand(session);
    }
    if (text === "/instance" || text.startsWith("/instance ")) {
      return deps.handleInstanceCommand(session, text);
    }
    if (text === "/project-instance" || text.startsWith("/project-instance ")) {
      return deps.handleProjectInstanceCommand(session, text);
    }
    if (text === "/create" || text.startsWith("/create ")) {
      return deps.handleCreateCommand(session, text);
    }
    if (text === "/import" || text.startsWith("/import ")) {
      return deps.handleImportCommand(session);
    }
    if (text === "/bind" || text.startsWith("/bind ")) {
      return deps.handleBindCommand(session, text);
    }
    if (text === "/unbind" || text.startsWith("/unbind ")) {
      return deps.handleUnbindCommand(session, text);
    }
    if (text === "/projects") {
      return deps.handleProjectsCommand(session);
    }
    if (text === "/models") {
      return deps.handleModelsCommand(session);
    }
    if (text === "/threads") {
      return deps.handleThreadsCommand(session);
    }
    if (text === "/use latest" || text.startsWith("/use ")) {
      return deps.handleUseCommand(session);
    }
    if (text === "/thread" || text.startsWith("/thread ")) {
      return deps.handleThreadCommand(session);
    }
    if (text === "/new" || text.startsWith("/new ")) {
      return deps.handleNewCommand(session);
    }
    if (text === "/cancel") {
      return deps.handleCancelCommand(session);
    }
    if (text === "/project" || text.startsWith("/project ")) {
      return deps.handleProjectCommand(session, text);
    }
    if (text === "/model" || text.startsWith("/model ")) {
      return deps.handleModelCommand(session, text);
    }
    return deps.handleRegularTask(session, text);
  };
}
