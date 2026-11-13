export default function handle(ctx) {
  return ctx.json({ ok: true, project: "hello-vjsx", message: "Hello from vhttpd Workbench", path: ctx.path }, 200);
}
