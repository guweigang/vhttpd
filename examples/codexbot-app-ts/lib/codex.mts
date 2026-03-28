function decodeThreadId(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.threadId === "string") {
    return result.threadId;
  }
  if (typeof result.thread_id === "string") {
    return result.thread_id;
  }
  if (result.thread && typeof result.thread.id === "string") {
    return result.thread.id;
  }
  return "";
}

function decodeTurnId(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.turnId === "string") {
    return result.turnId;
  }
  if (typeof result.turn_id === "string") {
    return result.turn_id;
  }
  if (result.turn && typeof result.turn.id === "string") {
    return result.turn.id;
  }
  return "";
}

function decodeThreadPath(result) {
  if (!result || typeof result !== "object") {
    return "";
  }
  if (typeof result.threadPath === "string") {
    return result.threadPath;
  }
  if (typeof result.thread_path === "string") {
    return result.thread_path;
  }
  if (result.thread && typeof result.thread.path === "string") {
    return result.thread.path;
  }
  return "";
}

function normalizePhase(value) {
  if (typeof value !== "string") {
    return "";
  }
  const phase = value.trim();
  return phase === "commentary" || phase === "final_answer" ? phase : "";
}

function pickFirstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value;
    }
  }
  return "";
}

function extractTextCandidate(value) {
  if (typeof value === "string" && value.trim() !== "") {
    return value.trim();
  }
  if (!value || typeof value !== "object") {
    return "";
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const text = extractTextCandidate(item);
      if (text) {
        return text;
      }
    }
    return "";
  }
  return pickFirstString(
    typeof value.text === "string" ? value.text : "",
    typeof value.message === "string" ? value.message : "",
    extractTextCandidate(value.content),
    extractTextCandidate(value.item),
    extractTextCandidate(value.parts),
  );
}

function extractOutputTextContent(content) {
  if (!Array.isArray(content)) {
    return "";
  }
  const parts = [];
  for (const part of content) {
    if (!part || typeof part !== "object") {
      continue;
    }
    if ((part.type === "output_text" || part.type === "text") && typeof part.text === "string" && part.text.trim() !== "") {
      parts.push(part.text.trim());
    }
  }
  return parts.join("\n").trim();
}

function decodeNotificationThreadId(payload, params) {
  return pickFirstString(
    params?.threadId,
    params?.thread_id,
    params?.thread?.id,
    payload?.threadId,
    payload?.thread_id,
    payload?.thread?.id,
  );
}

function decodeNotificationTurnId(payload, params) {
  return pickFirstString(
    params?.turnId,
    params?.turn_id,
    params?.turn?.id,
    payload?.turnId,
    payload?.turn_id,
    payload?.turn?.id,
  );
}

function decodeNotificationItemId(payload, params) {
  return pickFirstString(
    params?.itemId,
    params?.item_id,
    params?.item?.id,
    payload?.itemId,
    payload?.item_id,
    payload?.item?.id,
  );
}

function decodeNotificationThreadPath(payload, params) {
  return pickFirstString(
    params?.threadPath,
    params?.thread_path,
    params?.thread?.path,
    payload?.threadPath,
    payload?.thread_path,
    payload?.thread?.path,
  );
}

function decodeItemType(payload, params) {
  return pickFirstString(
    params?.item?.type,
    payload?.item?.type,
  );
}

function decodeItemRole(payload, params) {
  return pickFirstString(
    params?.item?.role,
    payload?.item?.role,
  );
}

function decodeNotificationPhase(payload, params) {
  return normalizePhase(
    pickFirstString(
      params?.phase,
      params?.item?.phase,
      payload?.phase,
      payload?.item?.phase,
    ),
  );
}

function decodeFinalText(payload, params) {
  const item = params?.item && typeof params.item === "object" ? params.item : payload?.item;
  if (!item || typeof item !== "object") {
    return "";
  }
  const contentText = extractOutputTextContent(item.content);
  const phase = normalizePhase(item.phase);
  if (item.type === "agentMessage" && phase === "final_answer" && typeof item.text === "string" && item.text.trim() !== "") {
    return item.text.trim();
  }
  if (item.type === "message" && item.role === "assistant" && phase === "final_answer") {
    return contentText;
  }
  if (phase === "final_answer") {
    return pickFirstString(
      typeof item.text === "string" ? item.text : "",
      contentText,
      extractTextCandidate(item.content),
    );
  }
  if (payload?.method === "rawResponseItem/completed" && item.type === "message" && item.role === "assistant" && contentText) {
    return contentText;
  }
  if (payload?.method === "item/completed" && contentText) {
    return contentText;
  }
  return "";
}

function decodeNotificationMessage(payload, params) {
  const finalText = decodeFinalText(payload, params);
  if (finalText) {
    return finalText;
  }
  return pickFirstString(
    params?.message,
    payload?.message,
    params?.item?.text,
    params?.item?.content?.text,
    params?.content?.text,
    extractTextCandidate(params?.item?.content),
    extractTextCandidate(params?.item),
    extractTextCandidate(params?.content),
    extractTextCandidate(payload?.content),
    extractTextCandidate(payload?.item),
    params?.error?.message,
    params?.status?.error?.message,
    payload?.error?.message,
  );
}

function decodeNotificationStatus(params) {
  if (typeof params?.status === "string" && params.status.trim() !== "") {
    return params.status;
  }
  if (params?.status && typeof params.status.type === "string" && params.status.type.trim() !== "") {
    return params.status.type;
  }
  return "";
}

export function parseCodexRpcResponse(frame) {
  const payload = frame.payloadJson({});
  const errorMessage = pickFirstString(
    payload?.error?.message,
    payload?.error?.data?.message,
  );
  return {
    streamId: frame.traceId || "",
    method: typeof payload.method === "string" ? payload.method : "",
    result: payload.result && typeof payload.result === "object" ? payload.result : {},
    hasError: !!payload.has_error,
    raw: payload,
    threadId: decodeThreadId(payload.result),
    turnId: decodeTurnId(payload.result),
    threadPath: decodeThreadPath(payload.result),
    errorMessage,
  };
}

export function parseCodexNotification(frame) {
  const payload = frame.payloadJson({});
  const params = payload.params && typeof payload.params === "object" ? payload.params : {};
  const finalText = decodeFinalText(payload, params);
  const message = decodeNotificationMessage(payload, params);
  return {
    streamId: frame.traceId || "",
    method: typeof payload.method === "string" ? payload.method : "",
    params,
    raw: payload,
    delta: typeof params.delta === "string" ? params.delta : "",
    message,
    finalText,
    status: decodeNotificationStatus(params),
    threadId: decodeNotificationThreadId(payload, params),
    turnId: decodeNotificationTurnId(payload, params),
    itemId: decodeNotificationItemId(payload, params),
    itemType: decodeItemType(payload, params),
    itemRole: decodeItemRole(payload, params),
    phase: decodeNotificationPhase(payload, params),
    threadPath: decodeNotificationThreadPath(payload, params),
    errorMessage: pickFirstString(
      params?.error?.message,
      params?.status?.error?.message,
      payload?.error?.message,
      message,
    ),
  };
}
