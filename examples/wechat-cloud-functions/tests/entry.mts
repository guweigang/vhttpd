import getUser from "../functions/get-user.js";
import fixtures from "./fixtures.js";
import {createApplication, readConfig} from "../lib/application.mjs";

const config = readConfig(process.env);
// Test-only injection. app.mts has no configurable exchange endpoint.
const exchangeCode = async (code, config, signal) => {
  const response = await fetch(process.env.WCF_TEST_WECHAT_URL + "/sns/jscode2session?appid="
    + encodeURIComponent(config.appId) + "&secret=" + encodeURIComponent(config.appSecret)
    + "&js_code=" + encodeURIComponent(code) + "&grant_type=authorization_code", {signal});
  return JSON.parse(await response.text());
};

const functions = {getUser: getUser.main, ...fixtures};
const application = createApplication(functions, config, {exchangeCode});
// Only the deliberate timeout cases use a short deadline. Ordinary SQL and
// restart checks retain the production default under GC and machine load.
const timeoutApplication = createApplication(functions, {...config, functionTimeoutMs: 500}, {exchangeCode});
export default ctx => ["/functions/timeout", "/functions/late"].includes(ctx.path)
  ? timeoutApplication(ctx) : application(ctx);
