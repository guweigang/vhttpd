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

export function feishuCard(target, content, streamId, targetType = "chat_id") {
  const command = {
    type: "provider.message.send",
    provider: "feishu",
    target_type: targetType,
    target,
    message_type: "interactive",
    content: typeof content === "string" ? content : json(content || {}),
  };
  if (streamId) {
    command.stream_id = streamId;
  }
  return command;
}

export function feishuText(target, text, streamId, targetType = "chat_id") {
  const command = feishuCard(target, interactiveMarkdownCard(text), streamId, targetType);
  command.text = text;
  return command;
}

export function feishuUpdateCard(streamId, content) {
  return {
    type: "provider.message.update",
    provider: "feishu",
    stream_id: streamId,
    message_type: "interactive",
    content: typeof content === "string" ? content : json(content || {}),
  };
}

export function feishuUpdateText(streamId, text) {
  return feishuUpdateCard(streamId, interactiveMarkdownCard(text));
}

export function feishuStreamAppendText(streamId, text) {
  return {
    type: "stream.append",
    provider: "feishu",
    stream_id: streamId,
    text,
    metadata: {
      mode: "append",
    },
  };
}

export function feishuStreamFinish(streamId, templateContent = "") {
  return {
    type: "stream.finish",
    provider: "feishu",
    stream_id: streamId,
    message_type: "interactive",
    content: templateContent,
    metadata: {
      mode: "finish",
      finish: "true",
    },
  };
}

export function providerInstanceUpsert(provider, instance, config, desiredState = "connected") {
  return {
    type: "provider.instance.upsert",
    provider,
    instance,
    content: json(config || {}),
    metadata: {
      desired_state: desiredState,
    },
  };
}

export function providerInstanceEnsure(provider, instance) {
  return {
    type: "provider.instance.ensure",
    provider,
    instance,
  };
}

export function codexRpcCall(method, params, streamId, instance = "") {
  const command = {
    type: "provider.rpc.call",
    provider: "codex",
    method,
    params: typeof params === "string" ? params : json(params),
    stream_id: streamId,
  };
  if (instance) {
    command.instance = instance;
  }
  return command;
}

export function codexRpcReply(id, result, streamId = "", instance = "") {
  const command = {
    type: "provider.rpc.reply",
    provider: "codex",
    content: typeof result === "string" ? result : json(result || {}),
    metadata: {
      id: String(id || ""),
      result: typeof result === "string" ? result : json(result || {}),
    },
  };
  if (streamId) {
    command.stream_id = streamId;
  }
  if (instance) {
    command.instance = instance;
  }
  return command;
}

export function codexTurnStart(params, streamId, instance = "") {
  return codexRpcCall("turn/start", params, streamId, instance);
}

export function codexTurnInterrupt(threadId, turnId, streamId, instance = "") {
  return codexRpcCall("turn/interrupt", { threadId, turnId }, streamId, instance);
}

export function codexSessionClear(streamId, threadId = "", instance = "") {
  const command = {
    type: "session.clear",
    provider: "codex",
    stream_id: streamId,
  };
  if (instance) {
    command.instance = instance;
  }
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
