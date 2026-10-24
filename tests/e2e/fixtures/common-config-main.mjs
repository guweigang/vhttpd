export default function handle(ctx) {
  return ctx.json({ ok: true, project: "hello-vjsx", path: ctx.path }, 200);
}
