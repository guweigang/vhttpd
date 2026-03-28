const bot = {
  http(ctx) {
    return ctx.json(
      {
        ok: true,
        kind: "http",
        dispatchKind: ctx.runtime.dispatchKind,
        path: ctx.path,
      },
      200,
    );
  },

  websocket_upstream(frame) {
    const payload = frame.payloadJson({});
    const prompt =
      typeof payload.text === "string" && payload.text.trim() !== ""
        ? payload.text
        : "empty";

    return {
      handled: true,
      commands: [
        {
          type: "provider.message.send",
          provider: frame.provider,
          instance: frame.instance,
          target: frame.target,
          target_type: frame.targetType || "chat_id",
          message_type: "text",
          text: `received: ${prompt}`,
          metadata: {
            event_type: frame.eventType,
            dispatch_kind: frame.runtime.dispatchKind,
          },
        },
      ],
    };
  },
};

export default bot;
