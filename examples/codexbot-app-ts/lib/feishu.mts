function decodeJsonString(raw, fallbackValue) {
  if (typeof raw !== "string" || raw.trim() === "") {
    return fallbackValue;
  }
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallbackValue;
  }
}

function pickFirstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return "";
}

export function parseFeishuInboundFrame(frame) {
  const payload = frame.payloadJson({});
  const event = payload.event || {};
  const message = event.message || {};
  const sender = event.sender || {};
  const senderId = sender.sender_id || {};
  const metadata = frame && typeof frame.metadata === "object" ? frame.metadata : {};
  const content = decodeJsonString(message.content, {});
  const text =
    typeof content.text === "string"
      ? content.text.trim()
      : "";
  const chatId = pickFirstString(message.chat_id, metadata.chat_id);
  const messageId = pickFirstString(message.message_id, metadata.message_id);
  const rootId = pickFirstString(message.root_id, metadata.root_id);
  const parentId = pickFirstString(message.parent_id, metadata.parent_id);
  const threadKey = pickFirstString(rootId, parentId);
  const replyTargetType = threadKey && messageId ? "message_id" : "chat_id";
  const replyTarget = replyTargetType === "message_id" ? messageId : chatId;
  const sessionKey = threadKey ? `${chatId}::thread:${threadKey}` : chatId;

  return {
    eventType: frame.eventType,
    chatId,
    messageId,
    messageType: typeof message.message_type === "string" ? message.message_type : "",
    rootId,
    parentId,
    threadKey,
    sessionKey,
    replyTarget,
    replyTargetType,
    text,
    senderOpenId:
      typeof senderId.open_id === "string" ? senderId.open_id : "",
    raw: payload,
  };
}
