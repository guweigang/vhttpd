import test, {assert, exampleRoot} from './support.mjs';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {loadFunctions} from '../lib/cloud/loader.mjs';
import {createCloudInvoker} from '../lib/cloud/runtime.mjs';
import {createDatabase} from '../lib/cloud/database.mjs';
import {readConfig} from '../lib/application.mjs';
import {encode, CloudError} from '../lib/cloud/errors.mjs';

const config = {...readConfig({WECHAT_APP_ID: 'test-app', WECHAT_APP_SECRET: 'secret'}), functionTimeoutMs: 100};
const identity = who => Object.freeze({APPID: 'test-app', OPENID: who, UNIONID: '', userId: who});
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const runtime = who => ({requestId: who, laneId: 0, db: {query: async () => ({rows: []})}});

test('application environments stay lexical and excluded callbacks never enter the user registry', async () => {
  const root = mkdtempSync(join(tmpdir(), 'wcf-environment-'));
  const original = process.env.WCF_LEXICAL_TEST;
  try {
    mkdirSync(join(root, 'visible'));
    mkdirSync(join(root, 'callback'));
    writeFileSync(join(root, 'visible', 'index.js'), 'exports.main=async()=>({value:process.env.WCF_LEXICAL_TEST});');
    // Deliberately missing index.js: exclusion must happen before entry loading.
    const make = value => createCloudInvoker(loadFunctions(root, {include: ['visible'], environment: {WCF_LEXICAL_TEST: value}}));
    const a = make('first'), b = make('second');
    const results = await Promise.all([a('visible', {}, identity('alice'), runtime('alice'), config),
      b('visible', {}, identity('bob'), runtime('bob'), config)]);
    assert.deepEqual(results, [{value: 'first'}, {value: 'second'}]);
    assert.equal(process.env.WCF_LEXICAL_TEST, original);
    await assert.rejects(a('callback', {}, identity('alice'), runtime('alice'), config), error => error.code === 'FUNCTION_NOT_FOUND');
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('legacy missing-document codes and configurable UTF-8 budgets preserve caller checks', () => {
  const error = new CloudError('DOCUMENT_NOT_FOUND');
  assert.equal(error.code, 'DOCUMENT_NOT_FOUND');
  assert.equal(error.errCode, error.code);
  assert.equal(encode('测'.repeat(1000), 4000).length, 1002);
  assert.throws(() => encode('测'.repeat(1000), 2000));
  assert.throws(() => readConfig({WECHAT_APP_ID: 'a', WECHAT_APP_SECRET: 's', WECHAT_BODY_LIMIT_BYTES: 0}));
});

test('MySQL binds repeated JSON expressions positionally and locks mutation reads', async () => {
  const calls = [];
  const document = {_id: 'a', count: 2, nested: {keep: '中文', remove: true}};
  const scope = {driver: 'mysql', appId: 'app', env: 'test', documentLimitBytes: 1048576,
    check() {},
    async query(sql, params) {
      calls.push({sql, params});
      assert.equal((sql.match(/\?/g) || []).length, params.length);
      return {rows: sql.includes('FOR UPDATE') ? [{document: JSON.stringify(document)}] : []};
    },
    async execute(sql, params) { calls.push({sql, params}); assert.equal((sql.match(/\?/g) || []).length, params.length); },
    transaction(work) { return work({...scope, inTransaction: true}); },
  };
  const db = createDatabase(scope), _ = db.command;
  await db.collection('items').where({count: _.gt(1).and(_.lt(9)), text: _.nin(["O'Reilly", '中文'])}).get();
  assert.ok(calls[0].sql.includes('JSON_TYPE'));
  assert.ok(!calls[0].sql.includes("O'Reilly"));
  assert.ok(!calls[0].sql.includes('::'));
  const result = await db.collection('items').doc('a').update({data: {count: _.mul(3), 'nested.remove': _.remove(), 'new.child': _.set(['值'])}});
  assert.equal(result.stats.updated, 1);
  assert.ok(calls[1].sql.endsWith('FOR UPDATE'));
  assert.deepEqual(JSON.parse(calls[2].params[0]), {_id: 'a', count: 6, nested: {keep: '中文'}, new: {child: ['值']}});
  await assert.rejects(db.collection('items').doc('a').update({data: {count: _.inc('1')}}));
});

test('CommonJS local/package/JSON dependencies share this invocation SDK, cycles and globals are isolated', async () => {
  const root = mkdtempSync(join(tmpdir(), 'wcf-cjs-'));
  try {
    const directory = join(root, 'identity');
    mkdirSync(join(directory, 'node_modules', 'helper'), {recursive: true});
    writeFileSync(join(directory, 'node_modules', 'helper', 'package.json'), '{"main":"main.js"}');
    writeFileSync(join(directory, 'node_modules', 'helper', 'main.js'), "exports.who = () => require('wx-server-sdk').getWXContext().OPENID;");
    writeFileSync(join(directory, 'settings.json'), '{"value":42}');
    writeFileSync(join(directory, 'cycle.js'), "exports.partial = require('./index').partial;");
    writeFileSync(join(directory, 'index.js'), `
      const cloud = require('wx-server-sdk'); cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
      exports.partial = 7; const cycle = require('./cycle');
      const helper = require('helper'); let calls = 0;
      exports.main = async (event) => {
        const before = cloud.getWXContext().OPENID;
        await new Promise(resolve => setTimeout(resolve, event.wait));
        return {before, after: helper.who(), calls: ++calls, cycle: cycle.partial,
          setting: require('./settings.json').value, forged: event.openid};
      };
    `);
    const invoke = createCloudInvoker(loadFunctions(root));
    const outputs = await Promise.all(['alice', 'bob'].map((who, index) => invoke('identity',
      {wait: index ? 1 : 10, openid: 'forged'}, identity(who), runtime(who), config)));
    assert.deepEqual(outputs, ['alice', 'bob'].map(who => ({before: who, after: who, calls: 1, cycle: 7, setting: 42, forged: who})));
    assert.equal(process.env.WX_OPENID, undefined);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('nested functions inherit identity, clone events/results, reject unknown names and bound recursion', async () => {
  const invoke = createCloudInvoker({
    parent: cloud => async event => {
      cloud.init();
      const value = await cloud.callFunction({name: 'child', data: event});
      assert.equal(event.changed, undefined);
      return {child: value.result, id: value.requestID, parent: cloud.getWXContext().OPENID};
    },
    child: cloud => async event => { event.changed = true; return cloud.getWXContext(); },
    recurse: cloud => async () => { cloud.init(); return cloud.callFunction({name: 'recurse'}); },
  });
  const result = await invoke('parent', {}, identity('alice'), runtime('one'), config);
  assert.equal(result.child.OPENID, 'alice');
  assert.equal(result.child.ENV, 'local');
  assert.equal(result.parent, 'alice');
  assert.match(result.id, /^one:/);
  await assert.rejects(invoke('missing', {}, identity('a'), runtime('a'), config), e => e.code === 'FUNCTION_NOT_FOUND');
  await assert.rejects(invoke('recurse', {}, identity('a'), runtime('a'), config), e => e.code === 'CALL_DEPTH_EXCEEDED');
});

test('saved SDK references reject after return/timeout, even while another invocation runs', async () => {
  let saved, late;
  const invoke = createCloudInvoker({
    slow: cloud => async () => {
      cloud.init(); saved = cloud;
      setTimeout(() => { try { cloud.getWXContext(); } catch (error) { late = error; } }, 35);
      await pause(100);
    },
    next: cloud => async () => { await pause(30); return cloud.getWXContext().OPENID; },
  });
  await assert.rejects(invoke('slow', {}, identity('alice'), runtime('a'), {...config, functionTimeoutMs: 20}), e => e.code === 'FUNCTION_TIMEOUT');
  assert.equal(await invoke('next', {}, identity('bob'), runtime('b'), config), 'bob');
  assert.ok(late);
  assert.throws(() => saved.getWXContext());
});

test('regular writes commit independently; explicit transaction errors/timeouts await rollback and close handles', async () => {
  let committed = 0, rolledBack = 0, saved, writes = 0;
  const rt = {requestId: 'tx', db: {
    query: async () => { writes++; return {rows: [{affected: '1'}]}; },
    transaction: async callback => {
      try { const result = await callback({query: async () => ({rows: [{affected: '1'}]})}); committed++; return result; }
      catch (error) { assert.notEqual(error.name, 'TimeoutError'); await pause(5); rolledBack++; throw error; }
    },
  }};
  const invoke = createCloudInvoker({
    regular: cloud => async () => { cloud.init(); await cloud.database().collection('x').doc('a').update({data: {a: 1}}); throw Error('body failed'); },
    tx: cloud => async event => {
      cloud.init();
      return cloud.database().runTransaction(async tx => {
        saved = tx;
        await tx.collection('x').doc('a').update({data: {a: 2}});
        if (event.timeout) await pause(100);
        if (event.fail) throw Object.assign(Error('failure'), {name: 'TimeoutError'});
        return 42;
      });
    },
  });
  await assert.rejects(invoke('regular', {}, identity('a'), rt, config));
  assert.equal(writes, 1); assert.equal(rolledBack, 0);
  assert.equal(await invoke('tx', {}, identity('a'), rt, config), 42);
  assert.equal(committed, 1);
  await assert.rejects(saved.collection('x').doc('a').get());
  await assert.rejects(invoke('tx', {fail: true}, identity('a'), rt, config));
  assert.equal(rolledBack, 1);
  await assert.rejects(invoke('tx', {timeout: true}, identity('a'), rt, {...config, functionTimeoutMs: 20}), e => e.code === 'FUNCTION_TIMEOUT');
  assert.equal(rolledBack, 2);
});

test('SQL operations bind all identity, collection, document, path and data values; counts use RETURNING', async () => {
  const queries = [];
  const db = createDatabase({appId: 'app', env: 'dev', query: async (sql, params) => {
    queries.push({sql, params});
    return {rows: sql.includes('AS affected') ? [{affected: '2'}] : sql.includes('AS total') ? [{total: '3'}] : []};
  }});
  const attack = "'); DROP TABLE wcf_documents; --";
  assert.deepEqual(await db.collection('users').where({_openid: attack, age: db.command.gte(18).and(db.command.lt(60))}).get(),
    {data: [], errMsg: 'collection.get:ok'});
  assert.ok(queries[0].params.includes(JSON.stringify(attack)));
  assert.ok(!queries[0].sql.includes(attack));
  assert.ok(queries[0].params.includes('app') && queries[0].params.includes('dev'));
  const updated = await db.collection('users').where({active: true}).update({data: {visits: db.command.inc(1)}});
  assert.equal(updated.stats.updated, 2);
  assert.match(queries[1].sql, /RETURNING 1/);
  assert.equal((await db.collection('users').count()).total, 3);
  assert.throws(() => db.collection('users;DROP'));
  assert.throws(() => db.collection('users').where({'x);DROP': 1}));
  await assert.rejects(db.collection('users').doc('x').update({data: {_id: 'y'}}));
  await assert.rejects(db.collection('users').doc('x').set({data: {missing: undefined}}));
  await assert.rejects(db.collection('users').limit(1).remove());
  await assert.rejects(db.collection('users').doc('x').update({data: {a: 1, 'a.b': 2}}));
  assert.throws(() => db.collection('users').aggregate(), e => e.errCode === 'NOT_SUPPORTED');
});

test('environment/unsupported features fail explicitly; shipped functions load unchanged', async () => {
  const invoke = createCloudInvoker({
    bad: cloud => () => cloud.init({env: 'other'}),
    storage: cloud => () => cloud.uploadFile({}),
    ...loadFunctions(join(exampleRoot, 'cloudfunctions')),
  });
  await assert.rejects(invoke('bad', {}, identity('a'), runtime('a'), config), e => e.code === 'ENV_NOT_FOUND');
  await assert.rejects(invoke('storage', {}, identity('a'), runtime('a'), config), e => e.code === 'NOT_SUPPORTED');
  // The test adapter can return a stored profile after a write.
  let document;
  const rt = runtime('a');
  rt.db.query = async (sql, params) => {
    if (sql.startsWith('INSERT')) { document = JSON.parse(params[4]); return {rows: [{created: 'true'}]}; }
    return {rows: document ? [{document: JSON.stringify(document)}] : []};
  };
  const result = await invoke('getUser', {}, identity('alice'), rt, config);
  assert.equal(result.openid, 'alice');
  assert.equal(result.user._openid, 'alice');
});
