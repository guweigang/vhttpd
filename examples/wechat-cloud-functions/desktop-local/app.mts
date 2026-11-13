// Desktop-only loopback demo. Identity is simulated, never verified by WeChat.
import {readConfig} from '../lib/application.mjs';
import {createCloudApplication} from '../lib/cloud/runtime.mjs';

const config = readConfig({WECHAT_APP_ID: 'desktop-local', WECHAT_APP_SECRET: 'desktop-local-demo-only',
  WECHAT_DB_DRIVER: 'pgsql', WECHAT_FUNCTION_TIMEOUT_MS: '3000'});
const application = createCloudApplication(config, {
  directory: '../cloudfunctions', env: 'desktop-local',
  exchangeCode: async () => ({openid: 'desktop-demo-user', session_key: 'unused-local-only', unionid: ''}),
});
export default ctx => /^127\.0\.0\.1:\d+$/.test(ctx.headers?.host || '')
  ? application(ctx) : ctx.json({error: {code: 'LOCAL_ONLY'}}, 403);
