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

function normalizeActionValue(value, fallbackValue = {}) {
  if (value && typeof value === "object") {
    return value;
  }
  if (typeof value === "string") {
    const parsed = decodeJsonString(value, null);
    if (parsed && typeof parsed === "object") {
      return parsed;
    }
  }
  return fallbackValue;
}

export function parseFeishuInboundFrame(frame) {
  const payload = frame.payloadJson({});
  const header = payload.header || {};
  const event = payload.event || {};
  const message = event.message || {};
  const sender = event.sender || {};
  const senderId = sender.sender_id || {};
  const action = event.action || {};
  const metadata = frame && typeof frame.metadata === "object" ? frame.metadata : {};
  const content = decodeJsonString(message.content, {});
  const text =
    typeof content.text === "string"
      ? content.text.trim()
      : "";
  const chatId = pickFirstString(message.chat_id, metadata.chat_id);
  const messageId = pickFirstString(message.message_id, frame?.messageId, metadata.message_id);
  const rootId = pickFirstString(message.root_id, metadata.root_id);
  const parentId = pickFirstString(message.parent_id, metadata.parent_id);
  const eventId = pickFirstString(header.event_id, metadata.event_id);
  const createTime = pickFirstString(message.create_time, metadata.create_time);
  const threadKey = pickFirstString(rootId, parentId);
  const replyTargetType = threadKey && messageId ? "message_id" : "chat_id";
  const replyTarget = replyTargetType === "message_id" ? messageId : chatId;
  const sessionKey = threadKey ? `${chatId}::thread:${threadKey}` : chatId;
  const openMessageId = pickFirstString(event.open_message_id, action.open_message_id, metadata.open_message_id);
  const eventKind = typeof frame.event === "string" && frame.event.trim() !== ""
    ? frame.event.trim()
    : (action && Object.keys(action).length ? "action" : "message");

  return {
    eventKind,
    eventType: frame.eventType,
    eventId,
    chatId,
    messageId,
    openMessageId,
    messageType: typeof message.message_type === "string" ? message.message_type : "",
    senderType: typeof sender.sender_type === "string" ? sender.sender_type : "",
    rootId,
    parentId,
    threadKey,
    createTime,
    receivedAt: Number(frame?.receivedAt || 0),
    sessionKey,
    replyTarget,
    replyTargetType,
    text,
    actionTag: typeof action.tag === "string" ? action.tag : "",
    actionValue: normalizeActionValue(action?.value, normalizeActionValue(metadata.action_value, {})),
    token: pickFirstString(payload.token, event.token, metadata.token),
    senderOpenId:
      typeof senderId.open_id === "string" ? senderId.open_id : "",
    raw: payload,
  };
}
