export async function handle(ctx) {
  if (ctx.path?.startsWith("/__vhttpd/events/upload.completed/")) {
    const event = ctx.jsonBody({});
    console.log("[vhttpd] upload completed", JSON.stringify({
      upload_id: event.upload_id,
      filename: event.filename,
      size: event.size,
      on_completed: event.on_completed,
      handler: event.handler ?? event.on_completed,
      trace_id: event.trace_id,
    }));
    return {
      status: 202,
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify({ ok: true, accepted: true, upload_id: event.upload_id, handler: event.handler ?? "" }),
    };
  }

  return {
    status: 404,
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify({ ok: false, error: "event_not_found" }),
  };
}
