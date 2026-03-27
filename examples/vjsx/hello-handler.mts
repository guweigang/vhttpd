function handle(ctx) {
  return ctx.json({
    ok: true,
    provider: ctx.runtime.provider,
    executor: ctx.runtime.executor,
    laneId: ctx.runtime.laneId,
    requestId: ctx.runtime.requestId,
    traceId: ctx.runtime.traceId,
    method: ctx.method,
    path: ctx.path,
    name: ctx.queryParam("name", "world"),
  }, 200);
}

export default handle;
