// card.action.trigger uses the current callback response envelope. The native
// WebSocket provider owns Base64 encoding of this JSON in its ACK payload.
export function cardCallbackResponse(content) {
  const data = typeof content === "string" ? JSON.parse(content) : content;
  if (!data || typeof data !== "object" || Array.isArray(data)) throw Error("invalid_callback_card");
  return JSON.stringify({ card: { type: "raw", data } });
}
