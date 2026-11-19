import fs from 'node:fs';
import path from 'node:path';
import crypto from './crypto-compat.mjs';
import {readStreamContent} from './fs-compat.mjs';
import {CloudError, invalid, unsupported, record} from './errors.mjs';

const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const fail = code => { throw new CloudError(code); };
const isBytes = value => Buffer.isBuffer(value) || value instanceof Uint8Array;
function integer(value, fallback, min, max) {
  const n = value ?? fallback;
  if (!Number.isSafeInteger(n) || n < min || n > max) invalid('invalid storage limit');
  return n;
}
function options(value, keys) {
  if (!record(value)) invalid('storage options must be an object');
  for (const key of Object.keys(value)) if (!keys.includes(key)) unsupported('storage option ' + key);
}
function cloudPath(value) {
  if (typeof value !== 'string' || !value || Buffer.byteLength(value) > 1024
    || /[\\\u0000-\u001f\u007f]/.test(value) || value.split('/').some(part => !part || part === '.' || part === '..')) invalid('invalid cloudPath');
  return value;
}
async function regular(filename, directory = false) {
  const stat = await fs.lstat(filename);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile())) fail('STORAGE_UNSAFE_PATH');
  return stat;
}

// Provider contract: initialize(), put(key, bytes), get(key, maxBytes), remove(key).
// Keys are opaque immutable versions. No provider sees client paths/identities.
// A future S3 provider can implement this contract without changing fileIDs or SDK calls.
export function createLocalDiskBackend({root}) {
  if (typeof root !== 'string' || !root || path.dirname(path.resolve(root)) === path.resolve(root)) invalid('private storage root required');
  const directory = path.resolve(root), objects = path.join(directory, 'objects');
  let ready;
  const initialize = () => ready ||= (async () => {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700});
    await regular(directory, true); fs.chmodSync(directory, 0o700);
    fs.mkdirSync(objects, {recursive: true, mode: 0o700});
    await regular(objects, true); fs.chmodSync(objects, 0o700);
  })();
  const locate = async key => {
    if (!/^[a-f0-9]{32}$/.test(key)) fail('STORAGE_UNSAFE_PATH');
    await initialize(); await regular(directory, true); await regular(objects, true);
    return path.join(objects, key + '.blob');
  };
  return Object.freeze({kind: 'filesystem', initialize,
    async signingKey() {
      await initialize(); const filename = path.join(directory, '.signing-key');
      if (!fs.existsSync(filename)) {
        const key = crypto.randomBytes(32).toString('hex');
        try { fs.writeFileSync(filename, key, {flag: 'wx', mode: 0o600}); }
        catch (error) { if (!fs.existsSync(filename)) throw error; }
      }
      await regular(filename); fs.chmodSync(filename, 0o600);
      let value = fs.readFileSync(filename, 'utf8');
      for (let attempt = 0; value.length !== 64 && attempt < 20; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 10));
        value = fs.readFileSync(filename, 'utf8');
      }
      if (!/^[a-f0-9]{64}$/.test(value)) fail('STORAGE_INVALID_SIGNING_KEY');
      return value;
    },
    async put(key, bytes, guard = {}) { const filename = await locate(key); guard.check?.(); fs.writeFileSync(filename, bytes, {flag: 'wx', mode: 0o600}); },
    async get(key, maxBytes) {
      const filename = await locate(key), stat = await regular(filename);
      if (stat.size > maxBytes) fail('FILE_TOO_LARGE');
      const bytes = Buffer.from(fs.readFileSync(filename));
      if (bytes.length > maxBytes) fail('FILE_TOO_LARGE');
      return bytes;
    },
    async remove(key) { const filename = await locate(key); if (fs.existsSync(filename)) { await regular(filename); fs.rmSync(filename); } },
  });
}

export function createStorageService(settings) {
  options(settings, ['root', 'backend', 'kind', 'publicBaseURL', 'signingKey', 'maxFileBytes', 'urlTTLSeconds']);
  if (settings.kind && settings.kind !== 'filesystem' && !settings.backend) unsupported('storage backend ' + settings.kind);
  const backend = settings.backend || createLocalDiskBackend(settings);
  for (const method of ['initialize', 'put', 'get', 'remove']) if (typeof backend[method] !== 'function') invalid('invalid storage provider: ' + method);
  const maxBytes = integer(settings.maxFileBytes, 10 * 1024 * 1024, 1, 64 * 1024 * 1024);
  const defaultTTL = integer(settings.urlTTLSeconds, 600, 1, 3600);
  const base = String(settings.publicBaseURL || '').replace(/\/$/, '');
  if (!/^https:\/\/[^/?#]+$/.test(base) && !/^http:\/\/127\.0\.0\.1:\d+$/.test(base)) invalid('storage publicBaseURL must be an HTTPS origin or loopback HTTP');
  let secret;
  const signingKey = () => secret ||= (async () => {
    const key = settings.signingKey || await backend.signingKey?.();
    if (typeof key !== 'string' || Buffer.byteLength(key) < 32) invalid('storage signingKey requires at least 32 bytes');
    return key;
  })().catch(error => { if (error instanceof CloudError) throw error; fail('STORAGE_FAILED'); });
  const provider = async (scope, method, ...args) => {
    scope.check?.();
    try { return await backend[method](...args, {check: scope.check, signal: scope.signal}); }
    catch (error) {
      scope.check?.();
      if (error instanceof CloudError) throw error;
      fail('STORAGE_FAILED');
    }
  };
  const readBlob = async (scope, record) => {
    const bytes = await provider(scope, 'get', record.object_key, maxBytes);
    if (!isBytes(bytes)) fail('STORAGE_FAILED');
    const data = Buffer.from(bytes);
    scope.check?.();
    if (data.length !== Number(record.size_bytes) || hash(data) !== record.sha256) fail('STORAGE_CORRUPTED');
    return data;
  };
  const namespace = scope => hash(scope.appId + '\0' + scope.env).slice(0, 32);
  const externalID = (scope, id) => 'cloud://vhttpd/' + namespace(scope) + '/' + id;
  const parseID = (scope, value) => {
    const match = typeof value === 'string' && /^cloud:\/\/vhttpd\/([a-f0-9]{32})\/([a-f0-9]{64})$/.exec(value);
    if (!match || match[1] !== namespace(scope)) fail('FILE_NOT_FOUND');
    return match[2];
  };
  const sql = (scope, text, values, method = 'query') => {
    let i = 0; const statement = text.replace(/\?/g, () => scope.driver === 'mysql' ? '?' : '$' + (++i));
    return scope[method](statement, values.map(String));
  };
  const row = async (scope, id, lock = false) => {
    const result = await sql(scope, 'SELECT owner_id,cloud_path,object_key,size_bytes,sha256 FROM wcf_files WHERE app_id=? AND env_id=? AND file_id=?' + (lock ? ' FOR UPDATE' : ''), [scope.appId, scope.env, id]);
    return result.rows[0];
  };
  const owned = async (scope, fileID) => {
    const id = parseID(scope, fileID), record = await row(scope, id);
    if (!record || record.owner_id !== scope.identity.OPENID) fail('FILE_NOT_FOUND');
    return {id, record};
  };
  const authorize = scope => {
    scope.check();
    if (!scope.identity.OPENID) fail('UNAUTHORIZED');
    if (scope.transactions > 0 || scope.inTransaction) unsupported('storage inside a database transaction');
  };
  const signature = async (fileID, record, expires) => crypto.createHmac('sha256', await signingKey())
    .update(fileID + '\n' + record.object_key + '\n' + record.owner_id + '\n' + expires).digest('hex');
  async function content(value) {
    if (isBytes(value)) { if (value.length > maxBytes) fail('FILE_TOO_LARGE'); return Buffer.from(value); }
    try { const known = readStreamContent(value, maxBytes); if (known !== undefined) return known; }
    catch (error) { fail(error.code === 'FILE_TOO_LARGE' ? 'FILE_TOO_LARGE' : 'FILE_CONTENT_INVALID'); }
    if (value && typeof value[Symbol.asyncIterator] === 'function') {
      const chunks = []; let total = 0;
      for await (const chunk of value) {
        if (!isBytes(chunk)) invalid('file stream must yield bytes');
        total += chunk.length; if (total > maxBytes) fail('FILE_TOO_LARGE');
        chunks.push(Buffer.from(chunk));
      }
      return Buffer.concat(chunks, total);
    }
    invalid('fileContent must be Buffer, Uint8Array or a readable byte stream');
  }
  const service = {
    maxFileBytes: maxBytes,
    async uploadFile(scope, input) {
      authorize(scope); options(input, ['cloudPath', 'fileContent']);
      const logicalPath = cloudPath(input.cloudPath), data = await content(input.fileContent);
      scope.check(); await provider(scope, 'initialize');
      const id = hash(scope.identity.OPENID + '\0' + logicalPath), key = crypto.randomUUID().replace(/-/g, '');
      await provider(scope, 'put', key, data);
      let previous;
      {
        await scope.transaction(async tx => {
          previous = await row(tx, id, true);
          if (previous && previous.owner_id !== scope.identity.OPENID) fail('FILE_NOT_FOUND');
          const values = [scope.appId, scope.env, id, scope.identity.OPENID, logicalPath, key, data.length, hash(data)];
          const suffix = scope.driver === 'mysql'
            ? ' ON DUPLICATE KEY UPDATE object_key=VALUES(object_key),size_bytes=VALUES(size_bytes),sha256=VALUES(sha256),cloud_path=VALUES(cloud_path)'
            : ' ON CONFLICT (app_id,env_id,file_id) DO UPDATE SET object_key=EXCLUDED.object_key,size_bytes=EXCLUDED.size_bytes,sha256=EXCLUDED.sha256,cloud_path=EXCLUDED.cloud_path';
          await sql(tx, 'INSERT INTO wcf_files (app_id,env_id,file_id,owner_id,cloud_path,object_key,size_bytes,sha256) VALUES (?,?,?,?,?,?,?,?)' + suffix, values, 'execute');
        });
      }
      // A failed/unknown COMMIT may have succeeded: retain the new blob on errors.
      // This can leave an orphan, but never intentionally deletes a published version.
      // Metadata is authoritative. Failed physical cleanup leaves an inaccessible orphan.
      if (previous && previous.object_key !== key) { try { await provider(scope, 'remove', previous.object_key); } catch (_) { console.warn('STORAGE_CLEANUP_PENDING'); } }
      return {fileID: externalID(scope, id), statusCode: 200, errMsg: 'uploadFile:ok'};
    },
    async downloadFile(scope, input) {
      authorize(scope); options(input, ['fileID']);
      const {record} = await owned(scope, input.fileID);
      const data = await readBlob(scope, record);
      return {fileContent: data, statusCode: 200, errMsg: 'downloadFile:ok'};
    },
    async deleteFile(scope, input) {
      authorize(scope); options(input, ['fileList']);
      if (!Array.isArray(input.fileList) || !input.fileList.length || input.fileList.length > 50) invalid('fileList requires 1..50 fileIDs');
      const fileList = [];
      for (const fileID of input.fileList) {
        scope.check();
        try {
          const id = parseID(scope, fileID); let previous;
          await scope.transaction(async tx => {
            previous = await row(tx, id, true);
            if (!previous || previous.owner_id !== scope.identity.OPENID) { previous = undefined; return; }
            await sql(tx, 'DELETE FROM wcf_files WHERE app_id=? AND env_id=? AND file_id=?', [scope.appId, scope.env, id], 'execute');
          });
          if (!previous) fail('FILE_NOT_FOUND');
          try { await provider(scope, 'remove', previous.object_key); } catch (_) { console.warn('STORAGE_CLEANUP_PENDING'); }
          fileList.push({fileID, status: 0, errMsg: 'deleteFile:ok'});
        } catch (error) {
          if (error instanceof CloudError && error.code === 'FILE_NOT_FOUND') fileList.push({fileID, status: 1, errMsg: 'FILE_NOT_FOUND'});
          else throw error;
        }
      }
      return {fileList, errMsg: 'deleteFile:ok'};
    },
    async getTempFileURL(scope, input) {
      authorize(scope); options(input, ['fileList']);
      if (!Array.isArray(input.fileList) || !input.fileList.length || input.fileList.length > 50) invalid('fileList requires 1..50 fileIDs');
      const fileList = [];
      for (const item of input.fileList) {
        const fileID = typeof item === 'string' ? item : item?.fileID;
        if (typeof item !== 'string') options(item, ['fileID', 'maxAge']);
        const maxAge = integer(typeof item === 'string' ? undefined : item.maxAge, defaultTTL, 1, 3600);
        try {
          const {id, record} = await owned(scope, fileID), expires = Math.floor(Date.now() / 1000) + maxAge;
          const token = await signature(fileID, record, expires);
          fileList.push({fileID, tempFileURL: base + '/storage/file/' + id + '?expires=' + expires + '&signature=' + token, maxAge, status: 0, errMsg: 'getTempFileURL:ok'});
        } catch (error) {
          if (error instanceof CloudError && error.code === 'FILE_NOT_FOUND') fileList.push({fileID, tempFileURL: '', maxAge: 0, status: 1, errMsg: 'FILE_NOT_FOUND'});
          else throw error;
        }
      }
      return {fileList, errMsg: 'getTempFileURL:ok'};
    },
    async serve(scope, id, query) {
      const expires = query.expires, token = query.signature;
      if (!/^[a-f0-9]{64}$/.test(id) || !/^\d{1,12}$/.test(String(expires)) || !/^[a-f0-9]{64}$/.test(token || '')
        || Number(expires) <= Math.floor(Date.now() / 1000) || Number(expires) > Math.floor(Date.now() / 1000) + 3600) fail('FILE_NOT_FOUND');
      const record = await row(scope, id);
      if (!record) fail('FILE_NOT_FOUND');
      const expected = await signature(externalID(scope, id), record, expires);
      if (!crypto.timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(token, 'hex'))) fail('FILE_NOT_FOUND');
      const data = await readBlob(scope, record);
      const extension = path.extname(record.cloud_path).toLowerCase();
      const mime = {'.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.webp':'image/webp'}[extension] || 'application/octet-stream';
      return {data, mime};
    },
  };
  return Object.freeze(service);
}
