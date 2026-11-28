import {createCloudApplication} from '../../examples/wechat-cloud-functions/lib/cloud/runtime.mjs';
import {readConfig} from '../../examples/wechat-cloud-functions/lib/application.mjs';
export function application(side) {
  const config = readConfig({WECHAT_APP_ID:'fixture-app',WECHAT_APP_SECRET:'fixture-only',WECHAT_DB_DRIVER:'mysql',
    WECHAT_FUNCTION_TIMEOUT_MS:'10000',WECHAT_BODY_LIMIT_BYTES:'4194304'});
  const app = createCloudApplication(config,{directory:'tests/relay-takeover/cloudfunctions',env:'takeover-fixture',
    environment:{FIXTURE_SIDE:side},exchangeCode:async code => ({openid:code,session_key:'fixture-session-only'})});
  return async ctx => {
    if (ctx.path === '/fixture-ready') return ctx.json({ok:true,side});
    const result = await app(ctx);
    // A real committed result can be lost after execution. The remote must
    // return an explicit unknown result and never run the function again.
    if (side === 'local' && JSON.parse(ctx.bodyText('{}')).holdResponseMs) {
      await new Promise(resolve=>setTimeout(resolve,3000));
    }
    return result;
  };
}
