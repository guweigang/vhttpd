type PluginRequest = {
  op: string;
  payload: string;
};

function payload(req: PluginRequest): Record<string, any> {
  return JSON.parse(req.payload || "{}");
}

async function* streamFrames(prompt: string) {
  yield { content: "executor: ", done: false };
  yield { content: prompt || "ok", done: false };
  yield {
    usage: {
      prompt_tokens: Math.max(1, prompt.length),
      completion_tokens: 2,
      total_tokens: Math.max(1, prompt.length) + 2,
    },
    done: true,
  };
}

async function* responseEvents(prompt: string) {
  yield {
    type: "response.created",
    response: {
      id: "resp_vhttpd_executor",
      object: "response",
      status: "in_progress",
    },
    sequence_number: 1,
  };
  yield {
    type: "response.output_text.delta",
    delta: `executor: ${prompt || "ok"}`,
    output_index: 0,
    content_index: 0,
    sequence_number: 2,
  };
  yield {
    type: "response.completed",
    response: {
      id: "resp_vhttpd_executor",
      object: "response",
      status: "completed",
    },
    sequence_number: 3,
  };
}

export async function openai(req: PluginRequest) {
  if (req.op !== "chat.execute" && req.op !== "responses.execute") {
    return { not_handled: true };
  }

  const p = payload(req);
  const body = JSON.parse(p.body || "{}");
  const prompt = (body.messages || []).map((m: any) => m.content).join("\n");

  if (req.op === "responses.execute") {
    if (p.stream) {
      return responseEvents(prompt);
    }

    return {
      id: "resp_vhttpd_executor",
      object: "response",
      status: "completed",
      model: p.model,
      output: [{
        id: "msg_vhttpd_executor",
        type: "message",
        status: "completed",
        role: "assistant",
        content: [{
          type: "output_text",
          text: `executor: ${prompt || "ok"}`,
          annotations: [],
        }],
      }],
    };
  }

  // This is where a real executor app can call a private SDK or a
  // non-OpenAI-compatible HTTP service. The result returned to vhttpd is
  // normalized frames/data; vhttpd still owns the client-facing OpenAI response.

  if (p.stream) {
    return streamFrames(prompt);
  }

  return {
    content: `executor: ${prompt || "ok"}`,
    usage: {
      prompt_tokens: Math.max(1, prompt.length),
      completion_tokens: 2,
      total_tokens: Math.max(1, prompt.length) + 2,
    },
    done: true,
  };
}
