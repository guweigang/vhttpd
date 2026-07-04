function parseJson(value, fallback = {}) {
  try {
    return JSON.parse(value || "");
  } catch {
    return fallback;
  }
}

function handle(ctx) {
  const event = ctx.jsonBody({});
  return ctx.json({
    ok: true,
    provider: event.metadata?.provider || "feishu",
    event: event.event || "",
    trace_id: event.trace_id || "",
  }, 202);
}

export function handshake(req) {
  const payload = parseJson(req.payload);
  return {
    send: [{
      text: JSON.stringify({
        type: "hello",
        provider: payload.provider || "feishu",
        instance: payload.instance || "main",
      }),
    }],
  };
}

export function normalize(req) {
  const payload = parseJson(req.payload);
  const upstream = parseJson(payload.payload);
  return {
    topic: "provider.feishu",
    name: upstream.header?.event_type || payload.metadata?.event_type || "feishu.event",
    data: JSON.stringify(upstream.event || upstream),
    metadata: {
      ...payload.metadata,
      source: "feishu-websocket",
    },
    request_id: req.request_id,
    trace_id: req.trace_id,
  };
}

globalThis.__vhttpd_handle = handle;
export default handle;
