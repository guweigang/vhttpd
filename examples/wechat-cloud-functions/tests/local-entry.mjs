// TEST ONLY, plain JavaScript. Never deploy this entry or expose a public proxy.
import getUser from '../functions/get-user.js';
import {createApplication, readConfig} from '../lib/application.mjs';

const config = readConfig(process.env);
if (config.appId !== 'local-demo' || config.appSecret !== 'local-only-not-a-secret') {
  throw Error('local-entry requires disposable local-demo configuration');
}
// This deliberately DOES NOT validate wx.login codes. All local clients are the
// same fake user; only production app.mts performs real jscode2session exchange.
const app = createApplication({getUser: getUser.main}, config, {
  exchangeCode: async () => ({openid: 'local-demo-user', session_key: 'local-unused', unionid: ''}),
});
export default async ctx => {
  const host = ctx.headers?.host || '';
  if (!/^127\.0\.0\.1:\d+$/.test(host)) return ctx.json({error: {code: 'LOCAL_ONLY'}}, 403);
  return app(ctx);
};
