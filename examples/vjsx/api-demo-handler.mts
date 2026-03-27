function summarizeRuntime(ctx) {
  const snapshot = ctx.runtime.snapshot() || {};
  return {
    provider: ctx.runtime.provider,
    executor: ctx.runtime.executor,
    laneId: ctx.runtime.laneId,
    requestId: ctx.runtime.requestId,
    traceId: ctx.runtime.traceId,
    runtimeProfile: ctx.runtime.runtimeProfile,
    workerPoolSize: snapshot.worker_pool_size,
    activeWebsockets: snapshot.active_websockets,
    activeUpstreams: snapshot.active_upstreams,
  };
}

function summarizeRequest(ctx) {
  return {
    method: ctx.method,
    path: ctx.path,
    target: ctx.target,
    href: ctx.href,
    origin: ctx.origin,
    host: ctx.host,
    ip: ctx.ip,
    query: ctx.query,
    contentType: ctx.contentType(),
    accepts: ctx.accepts(),
    wantsJson: ctx.wantsJson(),
    wantsHtml: ctx.wantsHtml(),
  };
}

function handle(ctx) {
  const mode = ctx.queryParam("mode", "hello");

  ctx.runtime.emit("demo.request", {
    mode,
    method: ctx.method,
    path: ctx.path,
  });

  if (mode === "problem") {
    return ctx.problem(409, "Conflict", "demo conflict from vjsx", {
      error_class: "demo_conflict",
      request_id: ctx.requestId,
    });
  }

  if (mode === "accepted") {
    return ctx.accepted({
      queued: true,
      requestId: ctx.requestId,
      traceId: ctx.traceId,
    });
  }

  if (ctx.is("POST")) {
    if (!ctx.isJson()) {
      return ctx.unprocessableEntity({
        error: "expected_json_body",
        contentType: ctx.contentType(),
      });
    }
    const payload = ctx.jsonBody({});
    return ctx.created({
      ok: true,
      kind: "created",
      payload,
      request: summarizeRequest(ctx),
      runtime: summarizeRuntime(ctx),
    });
  }

  if (mode === "html") {
    return ctx.html(
      `<h1>vhttpd + vjsx</h1><p>${ctx.queryParam("name", "world")}</p><p>${ctx.href}</p>`,
      200,
    );
  }

  return ctx.ok({
    ok: true,
    kind: "hello",
    name: ctx.queryParam("name", "world"),
    request: summarizeRequest(ctx),
    runtime: summarizeRuntime(ctx),
  });
}

export default handle;
