import {readConfig} from "./lib/application.mjs";
import {createCloudApplication} from "./lib/cloud/runtime.mjs";

const config = readConfig(process.env);
export default createCloudApplication(config, {
  directory: process.env.WECHAT_FUNCTION_ROOT || './examples/wechat-cloud-functions/cloudfunctions',
  env: process.env.WECHAT_CLOUD_ENV || 'local',
});
