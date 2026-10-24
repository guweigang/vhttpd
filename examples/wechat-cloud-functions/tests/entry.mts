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

export default createApplication({getUser: getUser.main, ...fixtures}, config, {exchangeCode});
