export default function handle(ctx) {
  return ctx.json({ ok: true, project: "api-playground", method: ctx.method, path: ctx.path, name: ctx.queryParam("name", "developer") }, 200);
}
