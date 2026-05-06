type PluginRequest = {
  op: string;
  payload: string;
};

type ChatPayload = {
  model: string;
  stream: boolean;
  body: string;
};

function payload<T>(req: PluginRequest): T {
  return JSON.parse(req.payload || "{}") as T;
}

function chatBody(input: ChatPayload): Record<string, any> {
  return JSON.parse(input.body || "{}");
}

function routeChat(req: PluginRequest) {
  const input = payload<ChatPayload>(req);
  const body = chatBody(input);
  const model = input.model || body.model || "";

  if (model === "llama3.1" || model === "minimax-m2:cloud") {
    return {
      backend: "ollama",
      method: "POST",
      path: "/api/chat",
      body: JSON.stringify({
        model: model === "minimax-m2:cloud" ? "minimax_m2" : "llama3.1",
        messages: body.messages || [],
        tools: body.tools,
        stream: input.stream,
      }),
      stream_mode: "mapped",
      response_codec: "ndjson",
      output_protocol: "openai.chat.completion",
      mapper: "builtin",
    };
  }

  body.model = model || body.model;

  return {
    backend: "bailian_coding",
    method: "POST",
    path: "/chat/completions",
    body: JSON.stringify(body),
    stream_mode: "passthrough",
  };
}

export function openai(req: PluginRequest) {
  switch (req.op) {
    case "models":
      return {
        models: [
          "qwen3.6-plus",
          "qwen3.5-plus",
          "qwen3-coder-plus",
          "glm-5",
          "kimi-k2.5",
          "MiniMax-M2.5",
          "llama3.1",
          "minimax-m2:cloud",
        ],
      };
    case "chat.route":
      return routeChat(req);
    default:
      return { not_handled: true };
  }
}
