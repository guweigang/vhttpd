import {readConfig} from '../lib/application.mjs';
import {createCloudApplication} from '../lib/cloud/runtime.mjs';
import {loadFunctions} from '../lib/cloud/loader.mjs';

const root = process.env.WCF_EXAMPLE_ROOT;
const config = readConfig(process.env);
if (config.appId !== 'local-demo' || config.appSecret !== 'local-only-not-a-secret') throw Error('test-only local configuration required');
const options = {
  directory: root + '/cloudfunctions',
  extraFactories: loadFunctions(root + '/tests/cloudfunctions'),
  exchangeCode: async code => {
    if (!['alice', 'bob'].includes(code)) return {errcode: 40029};
    return {openid: code, session_key: 'local-unused', unionid: 'union-' + code};
  },
};
const normal = createCloudApplication(config, options);
const short = createCloudApplication({...config, functionTimeoutMs: 500}, options);
export default ctx => ['/functions/cloudTimeout', '/functions/cloudLate'].includes(ctx.path)
  ? short(ctx) : normal(ctx);
