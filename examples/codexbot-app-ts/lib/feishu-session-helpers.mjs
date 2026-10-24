export function createFeishuSessionHelpers(deps) {
  function feishuReplyText(session, text, streamId = "") {
    const once = streamId === "";
    // Serialization failure must precede the trusted issuance side effect.
    if (once) JSON.stringify({ text });
    const context = once ? deps.createReplyContext(session.instance || "main") : streamId;
    const command = deps.feishuText(session.replyTarget || session.chatId, text, context, session.replyTargetType || "chat_id");
    if (once) command.metadata.one_shot_reply = "1";
    return command;
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

// Append captured cleanup without signing, looking up state, or refreshing authority.
export function completeReplyResponse(response) {
  if (!response || !Array.isArray(response.commands)) return response;
  const commands = [];
  for (const command of response.commands) {
    const once = command?.metadata?.one_shot_reply === "1";
    if (once && (command.type !== "provider.message.send" || command.provider !== "feishu" || !command.stream_id || !command.metadata.stream_generation || !command.metadata.creation_token)) throw new Error("Reply cleanup requires captured send ownership");
    const wire = once ? { ...command, metadata: { ...command.metadata } } : command;
    if (once) delete wire.metadata.one_shot_reply;
    commands.push(wire);
    if (once) {
      commands.push({ type: "session.clear", provider: "feishu", instance: command.instance || "main", stream_id: command.stream_id, metadata: { stream_generation: command.metadata.stream_generation } });
    }
  }
  return { ...response, commands };
}
