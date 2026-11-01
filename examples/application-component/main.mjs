export default function handle(ctx) {
  return ctx.json({ ok: true, application: "component-demo", path: ctx.path }, 200);
}
