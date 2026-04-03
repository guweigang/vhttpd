export function isPlainPromptStream(stream) {
  const prompt = typeof stream?.prompt === "string" ? stream.prompt.trim() : "";
  return prompt !== "" && !prompt.startsWith("/");
}

export function createParentStreamOutput(deps) {
  function resolveParentTarget(stream) {
    const threadRootId = deps.threadRootIdFromSessionKey(stream?.sessionKey || "");
    if (threadRootId) {
      return {
        target: threadRootId,
        targetType: "message_id",
      };
    }
    return {
      target: stream?.chatId || "",
      targetType: "chat_id",
    };
  }

  function openParentStreamCard(stream, streamId = stream?.streamId || "", text = " ") {
    const { target, targetType } = resolveParentTarget(stream);
    return deps.feishuText(target, text, streamId, targetType);
  }

  function sendStreamText(stream, text, streamId = stream?.streamId || "") {
    const { target, targetType } = resolveParentTarget(stream);
    return deps.feishuText(target, text, streamId, targetType);
  }

  return {
    openParentStreamCard,
    sendStreamText,
  };
}
