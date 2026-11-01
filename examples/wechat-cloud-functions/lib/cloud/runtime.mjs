import {randomUUID} from 'node:crypto';
import {ApplicationError, createApplication, invokeFunction} from '../application.mjs';
import {loadFunctions} from './loader.mjs';
import {createDatabase} from './database.mjs';
import {createStorageService} from './storage.mjs';
import {CloudError, invalid, unsupported, name, record, encode} from './errors.mjs';

const DYNAMIC_CURRENT_ENV = Symbol('DYNAMIC_CURRENT_ENV');
const publicCodes = new Set(['INVALID_PARAM', 'NOT_SUPPORTED', 'DOCUMENT_NOT_FOUND', 'FUNCTION_NOT_FOUND',
  'INVOCATION_CLOSED', 'CALL_DEPTH_EXCEEDED', 'ENV_NOT_FOUND', 'FILE_NOT_FOUND', 'FILE_TOO_LARGE', 'FILE_CONTENT_INVALID']);

function selectEnv(options, env) {
  if (!record(options)) invalid('options must be an object');
  if (options.env !== undefined && options.env !== DYNAMIC_CURRENT_ENV && options.env !== env) throw new CloudError('ENV_NOT_FOUND');
  for (const key of Object.keys(options)) if (!['env', 'throwOnNotFound'].includes(key)) unsupported('option ' + key);
}

export function createCloud(scope, call) {
  let initialized = false, throwOnNotFound = true;
  const check = () => { scope.check(); if (!initialized) throw new CloudError('NOT_INITIALIZED'); };
  return Object.freeze({
    DYNAMIC_CURRENT_ENV,
    init(options = {}) {
      scope.check(); selectEnv(options, scope.env);
      if (options.throwOnNotFound !== undefined && typeof options.throwOnNotFound !== 'boolean') invalid('throwOnNotFound must be boolean');
      if (!initialized) { initialized = true; throwOnNotFound = options.throwOnNotFound !== false; }
    },
    getWXContext() { scope.check(); return scope.identity; },
    database(options = {}) {
      check(); selectEnv(options, scope.env);
      if (options.throwOnNotFound !== undefined && typeof options.throwOnNotFound !== 'boolean') invalid('throwOnNotFound must be boolean');
      return createDatabase(scope, {throwOnNotFound: options.throwOnNotFound ?? throwOnNotFound});
    },
    callFunction(options = {}) {
      check();
      if (!record(options)) invalid('callFunction options required');
      for (const key of Object.keys(options)) if (!['name', 'data', 'config'].includes(key)) unsupported('callFunction option ' + key);
      selectEnv(options.config || {}, scope.env);
      name(options.name, 'function name');
      if (options.data !== undefined && !record(options.data)) invalid('callFunction data must be object');
      if (scope.transactions > 0) unsupported('callFunction while a transaction is active');
      return scope.track(() => call(options.name, JSON.parse(encode(options.data || {}, scope.bodyLimitBytes))));
    },
    ...Object.fromEntries(['uploadFile', 'downloadFile', 'deleteFile', 'getTempFileURL'].map(method => [method, options => {
      if (!scope.storage) unsupported(method + '; configure storage first');
      check();
      return scope.track(() => scope.storage[method](scope, options), false);
    }])),
    openapi: new Proxy({}, {get: (_, key) => { unsupported('openapi.' + String(key)); }}),
  });
}

// Each invocation has a separate module graph and SDK closure. No lane-global
// current user and no process.env mutations, including for nested functions.
export function createCloudInvoker(factories, env = 'local', {storage} = {}) {
  name(env, 'environment');
  const registry = Object.freeze({...factories});
  async function invoke(functionName, event, identity, runtime, config, parent) {
    if (parent) parent.check();
    if (!Object.prototype.hasOwnProperty.call(registry, functionName)) throw new CloudError('FUNCTION_NOT_FOUND');
    const depth = parent ? parent.depth + 1 : 0;
    if (depth > 8) throw new CloudError('CALL_DEPTH_EXCEEDED');
    const deadlineAt = parent ? parent.deadlineAt : Date.now() + config.functionTimeoutMs;
    const pending = new Set();
    let active = true, expired = false, failure;
    const timeoutError = new ApplicationError('FUNCTION_TIMEOUT', 504);
    let rejectDeadline;
    const deadline = new Promise((_, reject) => { rejectDeadline = reject; });
    deadline.catch(() => {});
    const check = () => {
      if (expired || Date.now() >= deadlineAt) { expired = true; throw timeoutError; }
      if (!active) throw new CloudError('INVOCATION_CLOSED');
      if (parent) parent.check();
    };
    const timer = setTimeout(() => { expired = true; rejectDeadline(timeoutError); }, Math.max(1, deadlineAt - Date.now()));
    const pump = typeof globalThis.vhttpdHost?.database === 'function'
      ? setInterval(() => globalThis.vhttpdHost.database('__drain'), 5) : undefined;
    const signal = new AbortController();
    const wxContext = Object.freeze({APPID: identity.APPID, OPENID: identity.OPENID, UNIONID: identity.UNIONID, ENV: env});
    const scope = {
      signal: signal.signal, storage, driver: config.driver, appId: identity.APPID, env, identity: wxContext, depth, deadlineAt, check, transactions: 0,
      documentLimitBytes: config.documentLimitBytes, bodyLimitBytes: config.bodyLimitBytes,
      track(work, fatal = true) {
        let result;
        try { check(); result = Promise.resolve(work()); } catch (error) { result = Promise.reject(error); }
        pending.add(result);
        result.then(() => pending.delete(result), error => { pending.delete(result); if (fatal) failure = failure || error; });
        return result;
      },
      query(sql, params) {
        return scope.track(() => {
          if (scope.transactions > 0) unsupported('use transaction.collection while a transaction is active');
          return runtime.db.query(sql, params, {timeoutMs: config.databaseTimeoutMs});
        });
      },
      execute(sql, params) {
        return scope.track(() => {
          if (scope.transactions > 0) unsupported('use transaction.collection while a transaction is active');
          return runtime.db.execute(sql, params, {timeoutMs: config.databaseTimeoutMs});
        });
      },
      transaction(callback) {
        return scope.track(async () => {
          scope.transactions++;
          let entered = false;
          const admission = new AbortController();
          const abortAdmission = () => { if (!entered) admission.abort(); };
          // Stop a queued BEGIN at the function deadline, but let an entered
          // transaction take the awaited rollback path on a regular error.
          deadline.catch(abortAdmission);
          try {
            return await runtime.db.transaction(async tx => {
              entered = true;
              let txActive = true, tail = Promise.resolve(), txFailure;
              const txCheck = () => { check(); if (!txActive) throw new CloudError('INVOCATION_CLOSED'); };
              const submit = (kind, sql, params) => {
                let result;
                try {
                  txCheck();
                  result = tail.then(() => { txCheck(); return tx[kind](sql, params, {timeoutMs: config.databaseTimeoutMs}); });
                } catch (error) { result = Promise.reject(error); }
                tail = result.then(() => {}, error => { txFailure = txFailure || error; });
                return result;
              };
              const txScope = {...scope, inTransaction: true, check: txCheck,
                query: (sql, params) => submit('query', sql, params),
                execute: (sql, params) => submit('execute', sql, params),
              };
              try {
                check();
                if (config.driver === 'mysql') {
                  const isolation = await tx.query('SELECT @@transaction_isolation AS isolation_level', [], {timeoutMs: config.databaseTimeoutMs});
                  if (!['REPEATABLE-READ', 'SERIALIZABLE'].includes(isolation.rows[0]?.isolation_level)) {
                    throw new Error('MySQL cloud transactions require REPEATABLE READ or SERIALIZABLE');
                  }
                } else await tx.query('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE', [], {timeoutMs: config.databaseTimeoutMs});
                check();
                const value = await Promise.race([Promise.resolve().then(() => callback(txScope)), deadline]);
                await tail;
                if (txFailure) throw txFailure;
                check();
                return value;
              } catch (error) {
                // Do not let TimeoutError/AbortError names select the native
                // facade's detached cleanup path.
                const wrapped = new Error('cloud transaction failed');
                wrapped.cause = error;
                throw wrapped;
              } finally { txActive = false; }
            }, {signal: admission.signal, timeoutMs: config.functionTimeoutMs + config.databaseTimeoutMs + 5000});
          } catch (error) { throw error.cause || error; }
          finally { scope.transactions--; }
        });
      },
    };
    const cloud = createCloud(scope, async (child, data) => {
      const requestId = runtime.requestId + ':' + randomUUID();
      const result = await invoke(child, data, identity, {...runtime, requestId}, config, scope);
      return {result, requestID: requestId, requestId, errMsg: 'callFunction:ok'};
    });
    const context = Object.freeze({requestId: runtime.requestId, laneId: runtime.laneId,
      ...wxContext, getWXContext: () => { check(); return wxContext; }, signal: signal.signal});
    try {
      check();
      const cleanEvent = JSON.parse(encode(event, config.bodyLimitBytes));
      for (const key of ['context', 'wxContext', 'session_key', 'userId']) delete cleanEvent[key];
      for (const key of ['APPID', 'OPENID', 'UNIONID']) { cleanEvent[key] = identity[key]; cleanEvent[key.toLowerCase()] = identity[key]; }
      const main = registry[functionName](cloud);
      const result = await Promise.race([Promise.resolve().then(() => main(cleanEvent, context)), deadline]);
      // Join operations submitted before main returned; further SDK operations
      // are refused as soon as the function body has completed.
      active = false;
      await Promise.all(Array.from(pending));
      if (failure) throw failure;
      if (Date.now() >= deadlineAt || expired) throw timeoutError;
      const serialized = encode(result === undefined ? null : result, config.resultLimitBytes);
      return JSON.parse(serialized);
    } finally {
      active = false;
      // In particular, wait for explicit transactions to finish rollback before
      // returning timeout/error. Ordinary completed writes are not rolled back.
      await Promise.allSettled(Array.from(pending));
      clearTimeout(timer);
      if (pump !== undefined) clearInterval(pump);
      try { signal.abort(); } catch (_) {}
    }
  }
  return async (functionName, ...args) => {
    try { return await invoke(functionName, ...args); }
    catch (error) {
      if (error instanceof ApplicationError) throw error;
      if (error instanceof CloudError && publicCodes.has(error.errCode)) {
        throw new ApplicationError(error.errCode, ['FUNCTION_NOT_FOUND', 'FILE_NOT_FOUND'].includes(error.errCode) ? 404 : error.errCode === 'FILE_TOO_LARGE' ? 413 : 400);
      }
      throw new ApplicationError('FUNCTION_FAILED', 500);
    }
  };
}

export function createCloudApplication(config, {directory, env = 'local', exchangeCode, legacyFunctions = {}, extraFactories = {}, environment = {}, include, storage: storageOptions} = {}) {
  if (!['pgsql', 'mysql'].includes(config.driver)) throw new Error('unsupported cloud database driver');
  const factories = {...loadFunctions(directory, {environment, include}), ...extraFactories};
  const storage = storageOptions ? createStorageService(storageOptions) : config.storageRoot ? createStorageService({
    root: config.storageRoot, publicBaseURL: config.storageBaseURL,
    maxFileBytes: config.storageMaxFileBytes, urlTTLSeconds: config.storageURLTTLSeconds,
  }) : undefined;
  const invoke = createCloudInvoker(factories, env, {storage});
  const bridge = storage && createCloudInvoker({storageBridge: cloud => async event => {
    if (event.operation === 'upload') {
      if (typeof event.base64 !== 'string') invalid('invalid base64 file');
      if (event.base64.length > Math.ceil(storage.maxFileBytes / 3) * 4) throw new CloudError('FILE_TOO_LARGE');
      if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(event.base64)) invalid('invalid base64 file');
      const fileContent = Buffer.from(event.base64, 'base64');
      if (fileContent.toString('base64') !== event.base64) invalid('noncanonical base64');
      cloud.init(); return cloud.uploadFile({cloudPath: event.cloudPath, fileContent});
    }
    cloud.init();
    if (event.operation === 'delete') return cloud.deleteFile({fileList: event.fileList});
    if (event.operation === 'temp-url') return cloud.getTempFileURL({fileList: event.fileList});
    invalid('invalid storage operation');
  }}, env, {storage});
  const storageHTTP = storage && {
    bodyLimit: Math.ceil(storage.maxFileBytes / 3) * 4 + 8192,
    async authenticated(ctx, body, identity) {
      const operation = {'/storage/upload':'upload', '/storage/delete':'delete', '/storage/temp-url':'temp-url'}[ctx.path];
      if (!operation) throw new ApplicationError('NOT_FOUND', 404);
      const result = await bridge('storageBridge', {...body, operation}, identity, ctx.runtime, {...config, bodyLimitBytes: this.bodyLimit});
      return ctx.json(result, 200);
    },
    async public(ctx) {
      if (!ctx.path.startsWith('/storage/file/')) return undefined;
      if (ctx.method !== 'GET') throw new ApplicationError('METHOD_NOT_ALLOWED', 405);
      const pump = setInterval(() => globalThis.vhttpdHost?.database?.('__drain'), 5);
      try {
        const scope = {driver: config.driver, appId: config.appId, env,
          query: (sql, params) => ctx.runtime.db.query(sql, params, {timeoutMs: config.databaseTimeoutMs})};
        const result = await storage.serve(scope, ctx.path.slice('/storage/file/'.length), ctx.query);
        ctx.header('content-type', result.mime); ctx.header('x-content-type-options', 'nosniff');
        ctx.header('content-disposition', 'attachment'); ctx.header('referrer-policy', 'no-referrer');
        return {status: 200, headers: {'content-type': result.mime, 'cache-control':'private, no-store',
          'x-content-type-options':'nosniff', 'content-disposition':'attachment', 'referrer-policy':'no-referrer'}, bodyBase64: result.data.toString('base64')};
      } catch (error) {
        throw new ApplicationError(error.code === 'FILE_NOT_FOUND' ? 'FILE_NOT_FOUND' : 'STORAGE_FAILED', error.code === 'FILE_NOT_FOUND' ? 404 : 500);
      } finally { clearInterval(pump); }
    },
  };
  const functions = {...legacyFunctions}, names = new Map();
  for (const functionName of Object.keys(factories)) {
    const marker = () => {};
    functions[functionName] = marker;
    names.set(marker, functionName);
  }
  return createApplication(functions, config, {exchangeCode, storage: storageHTTP,
    invoke: (main, ...args) => names.has(main) ? invoke(names.get(main), ...args) : invokeFunction(main, ...args)});
}
