// Real WeChat authentication. Credentials stay in the ignored local runtime directory.
import {readFileSync} from 'node:fs';
import {readConfig} from '../lib/application.mjs';
import {createCloudApplication} from '../lib/cloud/runtime.mjs';

const credentials = JSON.parse(readFileSync('.runtime/wechat-credentials.json', 'utf8'));
// Missing credentials fail startup; this entry never falls back to fake identity.
const config = readConfig({WECHAT_APP_ID: credentials.WECHAT_APP_ID,
  WECHAT_APP_SECRET: credentials.WECHAT_APP_SECRET, WECHAT_DB_DRIVER: 'pgsql',
  WECHAT_STORAGE_ROOT: '.runtime/storage', WECHAT_STORAGE_BASE_URL: 'http://127.0.0.1:19886'});
export default createCloudApplication(config, {directory: '../cloudfunctions', env: 'desktop-local'});
