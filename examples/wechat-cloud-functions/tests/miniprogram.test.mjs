import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import clientModule from '../client/vhttpd.js';

const demo = new URL('../miniprogram/', import.meta.url);
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
function page() {
  let definition, session;
  const requests = [];
  let failure = false;
  const wx = {
    login: ({success}) => success({code: 'local-code-do-not-log'}),
    getStorageSync: () => session, setStorageSync: (_, value) => { session = value; },
    removeStorageSync: () => { session = undefined; },
    request(request) {
      requests.push(request.url);
      if (failure) return request.success({statusCode: 401, data: {error: {code: 'UNAUTHORIZED'}}});
      request.success({statusCode: 200, data: request.url.endsWith('/auth/login')
        ? {token: 'd'.repeat(64), expiresAt: Date.now() + 60000}
        : {result: {user: {display_name: 'Local user'}, openid: 'local-demo-user'}, requestId: 'demo-request'}});
    },
  };
  vm.runInNewContext(readFileSync(new URL('pages/vhttpd-demo/index.js', demo), 'utf8'), {
    wx, Page: value => { definition = value; },
    require: path => {
      if (path === '../../utils/vhttpd') return clientModule;
      if (path === '../../config') return {baseURL: 'http://127.0.0.1:19886'};
      throw Error('unexpected require ' + path);
    },
  });
  const instance = {...definition, data: JSON.parse(JSON.stringify(definition.data)),
    setData(patch) { Object.assign(this.data, patch); }};
  instance.onLoad();
  return {instance, requests, rejectRequests() { failure = true; }};
}

test('Mini Program ships the same client and valid page registration', () => {
  assert.equal(readFileSync(new URL('utils/vhttpd.js', demo), 'utf8'),
    readFileSync(new URL('../client/vhttpd.js', import.meta.url), 'utf8'));
  const app = JSON.parse(readFileSync(new URL('app.json', demo), 'utf8'));
  assert.ok(app.pages.includes('pages/vhttpd-demo/index'));
});

test('demo login, Promise and callback query are wired to the real client without rendering secrets', async () => {
  const {instance: p, requests} = page();
  await p.onLogin();
  assert.equal(p.data.loggedIn, true);
  assert.equal(p.data.busy, false);
  await p.onPromiseQuery();
  assert.match(p.data.userJSON, /local-demo-user/);
  assert.equal(p.data.requestId, 'demo-request');
  assert.deepEqual(Array.from(p.data.events), ['Promise → resolved']);
  p.onCallbackQuery();
  await tick();
  assert.deepEqual(Array.from(p.data.events), ['success', 'complete']);
  assert.equal(p.data.busy, false);
  assert.deepEqual(requests, ['http://127.0.0.1:19886/auth/login',
    'http://127.0.0.1:19886/functions/getUser', 'http://127.0.0.1:19886/functions/getUser']);
  assert.ok(!JSON.stringify(p.data).includes('d'.repeat(64)));
  assert.ok(!JSON.stringify(p.data).includes('local-code-do-not-log'));
  p.onClearSession();
  assert.equal(p.data.loggedIn, false);
  assert.equal(p.data.userJSON, '');
  p.onCallbackQuery();
  await tick();
  assert.deepEqual(Array.from(p.data.events), ['fail', 'complete']);
  assert.match(p.data.error, /LOGIN_REQUIRED/);
  assert.equal(requests.length, 3);
});

test('demo handles 401 and changing service URL resets identity and query results', async () => {
  const {instance: p, rejectRequests} = page();
  await p.onLogin();
  rejectRequests();
  p.onCallbackQuery();
  await tick();
  assert.equal(p.data.loggedIn, false);
  assert.equal(p.data.busy, false);
  assert.match(p.data.error, /UNAUTHORIZED/);
  assert.deepEqual(Array.from(p.data.events), ['fail', 'complete']);
  p.onBaseURLInput({detail: {value: 'https://api.example.test/'}});
  assert.equal(p.data.baseURL, 'https://api.example.test');
  assert.equal(p.data.local, false);
  assert.equal(p.data.error, '');
  assert.equal(p.data.userJSON, '');
  assert.equal(p._vhttpd, undefined);
});

test('invalid service URL is shown as an error and unloaded pages ignore late updates', async () => {
  const {instance: p, requests} = page();
  p.onBaseURLInput({detail: {value: 'http://unsafe.example.test'}});
  await p.onLogin();
  assert.match(p.data.error, /HTTPS/);
  assert.equal(p.data.busy, false);
  assert.equal(requests.length, 0);
  p.onUnload();
  const before = JSON.stringify(p.data);
  p.update({status: 'late update'});
  assert.equal(JSON.stringify(p.data), before);
});
