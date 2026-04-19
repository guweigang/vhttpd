function json(value) {
  return JSON.stringify(value);
}

export default {
  websocket(frame) {
    if (frame.event === "open") {
      return {
        accepted: true,
        commands: [
          { event: "set_meta", id: frame.id, key: "relay_server_id", value: "srv_demo" },
          { event: "set_meta", id: frame.id, key: "relay_role", value: "server-control" },
          { event: "set_meta", id: frame.id, key: "relay_version", value: "2" },
          { event: "join", id: frame.id, room: "relay:session:srv_demo" },
          { event: "send", targetId: frame.id, data: json({ type: "sync" }), opcode: "text" },
        ]
      };
    }
    if (frame.event === "message") {
      const payload = frame.dataJson(null);
      if (payload && payload.type === "ping") {
        return {
          accepted: true,
          commands: [
            { event: "send", targetId: frame.id, data: json({ type: "pong" }), opcode: "text" }
          ]
        };
      }
      return {
        accepted: true,
        commands: [
          {
            event: "send",
            targetId: frame.id,
            opcode: frame.opcode || "text",
            data: json({ data: frame.dataText(""), meta: frame.metadata || {} })
          },
        ],
      };
    }
    return { accepted: true, commands: [] };
  },
};
