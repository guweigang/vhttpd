export default function handle(ctx) {
  if (ctx.path === "/api/mcp-test") {
    if (ctx.method !== "GET") {
      return ctx.json({ ok: false, error: "method_not_allowed" }, 405);
    }
    const name = ctx.queryParam("name", "developer");
    return ctx.json({ ok: true, app: "api", source: "mcp", name, message: "Hello, " + name + "!" }, 200);
  }
  return ctx.json({ ok: true, project: "api-playground", method: ctx.method, path: ctx.path, name: ctx.queryParam("name", "developer") }, 200);
}
