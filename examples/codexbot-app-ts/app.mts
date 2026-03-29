import { createBotApp } from "./lib/bot-runtime.mjs";

const base = createBotApp();

const app = {
  ...base,

  async startup(runtime) {
    return base.startup ? base.startup(runtime) : { commands: [] };
  },

  async app_startup(runtime) {
    return base.app_startup ? base.app_startup(runtime) : { commands: [] };
  },
};

export default app;
