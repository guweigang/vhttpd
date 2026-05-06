type PluginRequest = {
  op: string;
  payload: string;
  request_id?: string;
  trace_id?: string;
  metadata?: Record<string, string>;
};

type ChatPayload = {
  model: string;
  stream: boolean;
  body: string;
};

type FallbackPayload = {
  body: string;
  failed_backend: string;
  status_code: number;
  error_code: string;
  error_message: string;
};

type MapFramePayload = {
  frame: string;
};

const publicModels = [
  "gpt-4o-mini",
  "llama3.1",
  "custom-agent",
  "executor-agent",
];

function jsonPayload<T>(req: PluginRequest): T {
  return JSON.parse(req.payload || "{}") as T;
}

function chatBody(payload: ChatPayload): Record<string, any> {
  return JSON.parse(payload.body || "{}");
}

function openaiPassthrough(payload: ChatPayload) {
  const body = chatBody(payload);
  return {
    backend: "openai",
    method: "POST",
    path: "/chat/completions",
    body: JSON.stringify(body),
    stream_mode: "passthrough",
  };
}

function ollamaMapped(payload: ChatPayload) {
  const body = chatBody(payload);
  return {
    backend: "ollama",
    method: "POST",
    path: "/api/chat",
    body: JSON.stringify({
      model: "llama3.1",
      messages: body.messages || [],
      tools: body.tools,
      stream: payload.stream,
    }),
    stream_mode: "mapped",
    response_codec: "ndjson",
    output_protocol: "openai.chat.completion",
    mapper: "builtin",
  };
}

function customMapped(payload: ChatPayload) {
  const body = chatBody(payload);
  return {
    backend: "custom",
    method: "POST",
    path: "/chat",
    body: JSON.stringify({
      prompt: (body.messages || []).map((m: any) => m.content).join("\n"),
      stream: payload.stream,
    }),
    stream_mode: "mapped",
    response_codec: "ndjson",
    output_protocol: "openai.chat.completion",
    mapper: "plugin",
  };
}

function routeChat(req: PluginRequest) {
  const payload = jsonPayload<ChatPayload>(req);
  const model = payload.model || chatBody(payload).model || "";

  if (model === "llama3.1") {
    return ollamaMapped(payload);
  }

  if (model === "custom-agent") {
    return customMapped(payload);
  }

  if (model === "executor-agent") {
    return {
      backend: "custom_executor",
      method: "POST",
      path: "/executor/chat",
      body: payload.body,
      stream_mode: "executor",
    };
  }

  return openaiPassthrough(payload);
}

function routeResponses(req: PluginRequest) {
  const payload = jsonPayload<ChatPayload>(req);
  const body = chatBody(payload);
  const model = payload.model || body.model || "";

  if (model === "executor-agent") {
    return {
      backend: "custom_executor",
      method: "POST",
      path: "/executor/responses",
      body: payload.body,
      stream_mode: "executor",
      output_protocol: "openai.response",
    };
  }

  return {
    backend: "openai",
    method: "POST",
    path: "/responses",
    body: JSON.stringify(body),
    stream_mode: "passthrough",
    output_protocol: "openai.response",
  };
}

function mapCustomFrame(req: PluginRequest) {
  const payload = jsonPayload<MapFramePayload>(req);
  const frame = JSON.parse(payload.frame || "{}");

  if (frame.error) {
    return { error: { message: String(frame.error) } };
  }

  if (frame.tool_call) {
    return {
      tool_calls: [{
        index: frame.tool_call.index || 0,
        id: frame.tool_call.id,
        type: "function",
        function: {
          name: frame.tool_call.name,
          arguments: frame.tool_call.arguments || "",
        },
      }],
      finish_reason: "tool_calls",
      done: frame.done === true,
    };
  }

  return {
    content: frame.delta || frame.text || "",
    usage: frame.usage,
    done: frame.done === true,
  };
}

function fallback(req: PluginRequest) {
  const payload = jsonPayload<FallbackPayload>(req);

  if (payload.failed_backend === "openai" && payload.status_code >= 500) {
    const original = JSON.parse(payload.body || "{}");
    original.model = "llama3.1";
    original.stream = original.stream === true;
    return {
      backend: "ollama",
      method: "POST",
      path: "/api/chat",
      body: JSON.stringify({
        model: "llama3.1",
        messages: original.messages || [],
        stream: original.stream,
      }),
      stream_mode: "mapped",
      response_codec: "ndjson",
      output_protocol: "openai.chat.completion",
      mapper: "builtin",
    };
  }

  return { not_handled: true };
}

export function openai(req: PluginRequest) {
  switch (req.op) {
    case "models":
      return { models: publicModels };
    case "chat.route":
      return routeChat(req);
    case "responses.route":
      return routeResponses(req);
    case "chat.map_frame":
      return mapCustomFrame(req);
    case "chat.fallback":
      return fallback(req);
    default:
      return { not_handled: true };
  }
}
