function normalizeCardMarkdown(markdown) {
  const text = typeof markdown === "string" ? markdown.replace(/\r\n/g, "\n").trim() : "";
  return text.replace(/\n{3,}/g, "\n\n");
}

function interactiveMarkdownCard(markdown) {
  return JSON.stringify({
    elements: [
      {
        tag: "markdown",
        content: normalizeCardMarkdown(markdown) || " ",
      },
    ],
  });
}

function json(value) {
  return JSON.stringify(value);
}

export function feishuText(target, text, streamId, targetType = "chat_id") {
  const command = {
    type: "provider.message.send",
    provider: "feishu",
    target_type: targetType,
    target,
    message_type: "interactive",
    content: interactiveMarkdownCard(text),
    text,
  };
  if (streamId) {
    command.stream_id = streamId;
  }
  return command;
}

export function feishuUpdateText(streamId, text) {
  return {
    type: "provider.message.update",
    provider: "feishu",
    stream_id: streamId,
    message_type: "interactive",
    content: interactiveMarkdownCard(text),
  };
}

export function codexRpcCall(method, params, streamId) {
  return {
    type: "provider.rpc.call",
    provider: "codex",
    method,
    params: typeof params === "string" ? params : json(params),
    stream_id: streamId,
  };
}

export function codexTurnStart(params, streamId) {
  return codexRpcCall("turn/start", params, streamId);
}

export function codexTurnInterrupt(threadId, turnId, streamId) {
  return codexRpcCall("turn/interrupt", { threadId, turnId }, streamId);
}

export function codexSessionClear(streamId, threadId = "") {
  const command = {
    type: "session.clear",
    provider: "codex",
    stream_id: streamId,
  };
  if (threadId) {
    command.target = threadId;
    command.target_type = "thread_id";
  }
  return command;
}

export function feishuSessionClear(streamId) {
  return {
    type: "session.clear",
    provider: "feishu",
    stream_id: streamId,
  };
}
