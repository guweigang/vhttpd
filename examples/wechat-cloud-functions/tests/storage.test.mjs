import test, {assert} from './support.mjs';
import fs from 'node:fs';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'child_process';
import {createStorageService} from '../lib/cloud/storage.mjs';
import fsCompat from '../lib/cloud/fs-compat.mjs';

function fixture() {
  const rows = new Map();
  const scope = (who = 'alice', env = 'local', appId = 'test-app', driver = 'pgsql') => ({
    identity: {OPENID: who}, appId, env, driver, check() {}, transactions: 0,
    async query(sql, params) { const value = rows.get(params.slice(0, 3).join(':')); return {rows: value ? [{...value}] : []}; },
    async execute(sql, params) {
      const key = params.slice(0, 3).join(':');
      if (sql.startsWith('DELETE')) rows.delete(key);
      else rows.set(key, {owner_id: params[3], cloud_path: params[4], object_key: params[5], size_bytes: String(params[6]), sha256: params[7]});
      return {};
    },
    async transaction(work) { return work({...this, inTransaction: true}); },
  });
  return {rows, scope};
}
const expectCode = code => error => error.code === code;
function temp() { return fs.mkdtempSync(path.join(tmpdir(), 'wcf-storage-')); }

test('disk storage round-trips binary/streams, isolates owners/apps/envs and keeps stable overwrite IDs', async () => {
  const root = temp(), {scope} = fixture();
  try {
    const service = createStorageService({root, publicBaseURL: 'http://127.0.0.1:19886', maxFileBytes: 4096});
    const bytes = Buffer.from(Array.from({length: 256}, (_, i) => i));
    const alice = scope(), bob = scope('bob');
    const first = await service.uploadFile(alice, {cloudPath: '头像/示例.bin', fileContent: bytes});
    assert.deepEqual(Array.from((await service.downloadFile(alice, {fileID: first.fileID})).fileContent), Array.from(bytes));
    await assert.rejects(service.downloadFile(bob, {fileID: first.fileID}), expectCode('FILE_NOT_FOUND'));
    for (const other of [scope('alice', 'other'), scope('alice', 'local', 'other-app')]) {
      await assert.rejects(service.downloadFile(other, {fileID: first.fileID}), expectCode('FILE_NOT_FOUND'));
    }
    const secondUser = await service.uploadFile(bob, {cloudPath: '头像/示例.bin', fileContent: Buffer.from('bob')});
    assert.notEqual(first.fileID, secondUser.fileID);
    const urls = await service.getTempFileURL(alice, {fileList: [first.fileID, secondUser.fileID]});
    assert.equal(urls.fileList[0].status, 0); assert.equal(urls.fileList[1].status, 1);
    const parsed = new URL(urls.fileList[0].tempFileURL), id = parsed.pathname.split('/').pop(), query = Object.fromEntries(parsed.searchParams);
    assert.deepEqual(Array.from((await service.serve(alice, id, query)).data), Array.from(bytes));
    const streamPath = path.join(root, 'source.bin'); fs.writeFileSync(streamPath, Buffer.from([0, 255, 128, 65]));
    const replaced = await service.uploadFile(alice, {cloudPath: '头像/示例.bin', fileContent: fsCompat.createReadStream(streamPath)});
    assert.equal(replaced.fileID, first.fileID);
    await assert.rejects(service.serve(alice, id, query), expectCode('FILE_NOT_FOUND'));
    assert.deepEqual(Array.from((await service.downloadFile(alice, {fileID: first.fileID})).fileContent), [0, 255, 128, 65]);
    const reloaded = createStorageService({root, publicBaseURL: 'http://127.0.0.1:19886'});
    const newURL = new URL((await service.getTempFileURL(alice, {fileList:[first.fileID]})).fileList[0].tempFileURL);
    assert.equal((await reloaded.serve(alice, id, Object.fromEntries(newURL.searchParams))).data.length, 4);
    assert.equal((await service.deleteFile(bob, {fileList: [first.fileID]})).fileList[0].status, 1);
    assert.equal((await service.deleteFile(alice, {fileList: [first.fileID]})).fileList[0].status, 0);
    await assert.rejects(service.serve(alice, id, Object.fromEntries(newURL.searchParams)), expectCode('FILE_NOT_FOUND'));
    assert.equal(fs.readdirSync(path.join(root, 'objects')).length, 1);
  } finally { fs.rmSync(root, {recursive:true, force:true}); }
});

test('storage rejects path escapes, oversize content, forged/expired URLs and symlinked storage directories', async () => {
  const root = temp(), outside = temp(), {scope} = fixture();
  const originalNow = Date.now;
  try {
    const service = createStorageService({root, publicBaseURL:'http://127.0.0.1:19886', maxFileBytes:4});
    const alice = scope();
    for (const cloudPath of ['../escape', '/absolute', 'dir/../bad', 'dir\\bad', 'bad\0name']) {
      await assert.rejects(service.uploadFile(alice,{cloudPath,fileContent:Buffer.from('a')}), expectCode('INVALID_PARAM'));
    }
    await assert.rejects(service.uploadFile(alice,{cloudPath:'big',fileContent:Buffer.from('12345')}), expectCode('FILE_TOO_LARGE'));
    const file = await service.uploadFile(alice,{cloudPath:'empty',fileContent:Buffer.from([])});
    const parsed = new URL((await service.getTempFileURL(alice,{fileList:[{fileID:file.fileID,maxAge:1}]})).fileList[0].tempFileURL);
    const id=parsed.pathname.split('/').pop(), query=Object.fromEntries(parsed.searchParams);
    await assert.rejects(service.serve(alice,id,{...query,signature:'0'.repeat(64)}), expectCode('FILE_NOT_FOUND'));
    Date.now = () => originalNow()+2000;
    await assert.rejects(service.serve(alice,id,query), expectCode('FILE_NOT_FOUND'));
    Date.now = originalNow;
    fs.rmSync(path.join(root,'objects'),{recursive:true});
    execFileSync('ln',['-s',outside,path.join(root,'objects')]);
    await assert.rejects(service.uploadFile(alice,{cloudPath:'linked',fileContent:Buffer.from('x')}), expectCode('STORAGE_UNSAFE_PATH'));
    assert.equal(fs.readdirSync(outside).length,0);
  } finally { Date.now=originalNow; fs.rmSync(root,{recursive:true,force:true}); fs.rmSync(outside,{recursive:true,force:true}); }
});

test('storage provider interface accepts independent adapters without leaking cloud paths into object keys', async () => {
  const blobs = new Map(), {scope}=fixture();
  const backend={async initialize(){},async put(key,data){assert.match(key,/^[a-f0-9]{32}$/);blobs.set(key,Buffer.from(data));},async get(key){return blobs.get(key);},async remove(key){blobs.delete(key);}};
  const service=createStorageService({backend,signingKey:'test-only-signing-key-with-32-bytes',publicBaseURL:'https://files.example.test'});
  const file=await service.uploadFile(scope(),{cloudPath:'path/does-not-reach-provider',fileContent:Buffer.from('adapter')});
  assert.equal((await service.downloadFile(scope(),{fileID:file.fileID})).fileContent.toString(),'adapter');
  assert.throws(()=>createStorageService({kind:'s3',root:'/tmp/unused',publicBaseURL:'https://files.example.test'}),expectCode('NOT_SUPPORTED'));
});

test('storage SDK handles close with their invocation and pending uploads cannot write after timeout', async () => {
  const {createCloudInvoker} = await import('../lib/cloud/runtime.mjs');
  const {readConfig} = await import('../lib/application.mjs');
  let saved, writes=0;
  const storage={async uploadFile(scope,input){await new Promise(resolve=>setTimeout(resolve,input.delay||1));scope.check();writes++;return {fileID:'fixture'};}};
  const invoke=createCloudInvoker({save:cloud=>async()=>{cloud.init();saved=cloud;return cloud.uploadFile({});},slow:cloud=>async()=>{cloud.init();return cloud.uploadFile({delay:50});}},'local',{storage});
  const config={...readConfig({WECHAT_APP_ID:'test-app',WECHAT_APP_SECRET:'test-only'}),functionTimeoutMs:1000};
  const identity={APPID:'test-app',OPENID:'alice',UNIONID:''}, runtime={requestId:'fixture',db:{}};
  await invoke('save',{},identity,runtime,config);
  assert.throws(()=>saved.uploadFile({}),expectCode('INVOCATION_CLOSED'));
  await assert.rejects(invoke('slow',{},identity,runtime,{...config,functionTimeoutMs:20}),expectCode('FUNCTION_TIMEOUT'));
  assert.equal(writes,1);
});
