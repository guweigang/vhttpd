import path from 'node:path';
import {readConfig} from './lib/application.mjs';
import {createCloudApplication, createCloudInvoker} from './lib/cloud/runtime.mjs';
import {loadFunctions} from './lib/cloud/loader.mjs';

let handlers;
function initialize(root) {
  const directory = path.join(root, 'cloudfunctions');
  const env = process.env.WECHAT_CLOUD_ENV || 'local';
  const smoke = createCloudInvoker(loadFunctions(directory, {include: ['hello']}), env);
  const application = process.env.WECHAT_APP_ID || process.env.WECHAT_APP_SECRET
    ? createCloudApplication(readConfig(process.env), {directory, env})
    : undefined;
  return {smoke, application};
}

export default async function handle(ctx) {
  handlers ??= initialize(ctx.runtime.moduleRoot);
  const {smoke, application} = handlers;
  if (ctx.method === 'GET' && ctx.path === '/healthz') {
    const reply = await smoke('hello', {}, {APPID: 'health', OPENID: '', UNIONID: ''},
      ctx.runtime, {functionTimeoutMs: 1000, bodyLimitBytes: 4096, resultLimitBytes: 4096});
    return ctx.json({message: reply.message}, 200);
  }
  return application ? application(ctx) : ctx.json({error: 'wechat_not_configured'}, 503);
}
