import { createBotApp } from "./lib/bot-runtime.mjs";

const base = createBotApp();

export async function startup(runtime) {
  return base.startup ? base.startup(runtime) : { commands: [] };
}

export async function app_startup(runtime) {
  return base.app_startup ? base.app_startup(runtime) : { commands: [] };
}

export async function http(ctx) {
  if (!base.http) {
    return { status: 404, body: "Not Found" };
  }
  return base.http(ctx);
}

export async function websocket_upstream(frame) {
  if (!base.websocket_upstream) {
    return { handled: false, commands: [] };
  }
  return base.websocket_upstream(frame);
}

const app = {
  startup,
  app_startup,
  http,
  websocket_upstream,
};

export default app;
