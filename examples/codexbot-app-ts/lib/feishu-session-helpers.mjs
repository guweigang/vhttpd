export function createFeishuSessionHelpers(deps) {
  function feishuReplyText(session, text, streamId = "") {
    return deps.feishuText(session.replyTarget || session.chatId, text, streamId, session.replyTargetType || "chat_id");
  }

  function handleHelp(session) {
    return {
      handled: true,
      commands: [feishuReplyText(session, deps.helpText())],
    };
  }

  return {
    feishuReplyText,
    handleHelp,
  };
}
