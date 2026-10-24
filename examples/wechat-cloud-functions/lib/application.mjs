import { createHash, randomUUID } from "node:crypto";

export class ApplicationError extends Error {
  constructor(code, status = 500) {
    super(code);
    // Keep this distinct from TimeoutError/AbortError: the existing db facade
    // awaits rollback for ordinary callback errors, rather than detaching it.
    this.name = "CloudInvocationError";
    this.code = code;
    this.status = status;
  }
}

function integer(value, fallback, min, max) {
  const n = value === undefined || value === "" ? fallback : Number(value);
  if (!Number.isSafeInteger(n) || n < min || n > max) throw new Error("invalid application configuration");
  return n;
}

export function readConfig(env) {
  const config = {
    appId: env.WECHAT_APP_ID || "",
    appSecret: env.WECHAT_APP_SECRET || "",
    driver: env.WECHAT_DB_DRIVER || "pgsql",
    sessionSeconds: integer(env.WECHAT_SESSION_SECONDS, 3600, 1, 86400),
    functionTimeoutMs: integer(env.WECHAT_FUNCTION_TIMEOUT_MS, 3000, 10, 60000),
    databaseTimeoutMs: integer(env.WECHAT_DATABASE_TIMEOUT_MS, 30000, 1000, 120000),
    loginTimeoutMs: integer(env.WECHAT_LOGIN_TIMEOUT_MS, 5000, 100, 30000),
  };
  if (!config.appId || !config.appSecret || !["mysql", "pgsql"].includes(config.driver)) {
    throw new Error("WECHAT_APP_ID, WECHAT_APP_SECRET and WECHAT_DB_DRIVER are required");
  }
  return Object.freeze(config);
}

export function hash(value) {
  return createHash("sha256").update(value).digest("hex");
}

function parameters(config, count) {
  return Array.from({length: count}, (_, i) => config.driver === "mysql" ? "?" : "$" + (i + 1));
}

function objectBody(ctx) {
  const text = ctx.bodyText("");
  if (typeof text !== "string" || text.length > 16384) throw new ApplicationError("INVALID_BODY", 400);
  let value;
  try { value = JSON.parse(text); } catch (_) { throw new ApplicationError("INVALID_JSON", 400); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ApplicationError("INVALID_BODY", 400);
  return value;
}

function bearer(ctx) {
  // No body identity or x-wx-* header participates in authentication.
  const value = ctx.headers?.authorization;
  if (typeof value !== "string" || !/^Bearer [a-f0-9]{64}$/.test(value)) {
    throw new ApplicationError("UNAUTHORIZED", 401);
  }
  return value.slice(7);
}

// The endpoint is fixed in production. Tests inject the exchanger in code;
// neither client input nor an environment variable can redirect AppSecret.
export async function exchangeWechatCode(code, config, signal) {
  const query = "appid=" + encodeURIComponent(config.appId) + "&secret=" + encodeURIComponent(config.appSecret)
    + "&js_code=" + encodeURIComponent(code) + "&grant_type=authorization_code";
  try {
    const response = await fetch("https://api.weixin.qq.com/sns/jscode2session?" + query, {signal});
    if (response.status !== 200) throw new Error("exchange failed");
    const text = await response.text();
    if (text.length > 8192) throw new Error("oversize response");
    return JSON.parse(text);
  } catch (_) {
    // Native transport errors can contain the URL, code and secret. Never pass
    // them to an HTTP response or application log.
    throw new ApplicationError("WECHAT_UNAVAILABLE", 502);
  }
}

async function login(ctx, config, exchangeCode) {
  const body = objectBody(ctx);
  if (typeof body.code !== "string" || !body.code.trim() || body.code.length > 256) {
    throw new ApplicationError("INVALID_LOGIN_CODE", 400);
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.loginTimeoutMs);
  let rejectTimeout;
  const timeout = new Promise((_, reject) => { rejectTimeout = reject; });
  const onAbort = () => rejectTimeout(new ApplicationError("WECHAT_UNAVAILABLE", 502));
  controller.signal.addEventListener("abort", onAbort, {once: true});
  let identity;
  try {
    identity = await Promise.race([exchangeCode(body.code, config, controller.signal), timeout]);
  } catch (_) {
    throw new ApplicationError("WECHAT_UNAVAILABLE", 502);
  } finally {
    clearTimeout(timer);
    controller.signal.removeEventListener("abort", onAbort);
  }
  if (!identity || (identity.errcode !== undefined && identity.errcode !== 0)
      || typeof identity.openid !== "string" || !identity.openid || identity.openid.length > 128
      || typeof identity.session_key !== "string" || !identity.session_key
      || (identity.unionid !== undefined && (typeof identity.unionid !== "string" || identity.unionid.length > 128))) {
    throw new ApplicationError("INVALID_LOGIN_CODE", 401);
  }
  // Two independent CSPRNG-backed UUIDs provide 244 random bits. Only a hash of
  // this opaque token is persisted. session_key is deliberately not persisted.
  const token = (randomUUID() + randomUUID()).replace(/-/g, "");
  const tokenHash = hash(config.appId + ":" + token);
  const userId = hash(config.appId + ":" + identity.openid);
  const expires = Date.now() + config.sessionSeconds * 1000;
  const p = parameters(config, 6);
  await ctx.runtime.db.transaction(async db => {
    const sql = "INSERT INTO wcf_users (user_id, app_id, open_id, union_id, display_name) VALUES ("
      + p.slice(0, 5).join(",") + ") "
      + (config.driver === "mysql" ? "ON DUPLICATE KEY UPDATE user_id = user_id" : "ON CONFLICT (user_id) DO NOTHING");
    await db.execute(sql, [userId, config.appId, identity.openid, identity.unionid || "", "New user"]);
    await db.execute("INSERT INTO wcf_sessions (token_hash, app_id, user_id, open_id, union_id, expires_ms) VALUES ("
      + p.join(",") + ")", [tokenHash, config.appId, userId, identity.openid, identity.unionid || "", String(expires)]);
  }, {timeoutMs: config.databaseTimeoutMs});
  return {token, expiresAt: expires};
}

async function authenticate(ctx, config) {
  const tokenHash = hash(config.appId + ":" + bearer(ctx));
  const p = parameters(config, 3);
  const result = await ctx.runtime.db.query("SELECT user_id, open_id, union_id FROM wcf_sessions WHERE token_hash = "
    + p[0] + " AND app_id = " + p[1] + " AND expires_ms > " + p[2],
    [tokenHash, config.appId, String(Date.now())], {timeoutMs: config.databaseTimeoutMs});
  if (result.rows.length !== 1) throw new ApplicationError("UNAUTHORIZED", 401);
  const row = result.rows[0];
  return Object.freeze({APPID: config.appId, OPENID: row.open_id, UNIONID: row.union_id || "", userId: row.user_id});
}

export async function invokeFunction(main, event, identity, runtime, config) {
  let open = true, accepting = true, entered = false, expired = false, timer;
  // Keep compatibility await responsive while business code waits on timers
  // between DB calls. Native DB operations otherwise own this pump only while
  // their individual Promise is pending. This runs on the owning JS lane.
  const pump = typeof globalThis.vhttpdHost?.database === "function"
    ? setInterval(() => globalThis.vhttpdHost.database("__drain"), 5) : undefined;
  const admission = new AbortController();
  const signal = new AbortController();
  const deadlineError = new ApplicationError("FUNCTION_TIMEOUT", 504);
  const deadlineAt = Date.now() + config.functionTimeoutMs;
  const checkDeadline = () => {
    if (expired || Date.now() >= deadlineAt) {
      expired = true;
      throw deadlineError;
    }
  };
  let rejectDeadline;
  const deadline = new Promise((_, reject) => { rejectDeadline = reject; });
  // A timeout may fire while BEGIN is waiting for pool admission, before the
  // callback starts. Attach a rejection handler immediately.
  deadline.catch(() => {});
  timer = setTimeout(() => {
    expired = true;
    open = false;
    accepting = false;
    try { signal.abort(); } catch (_) {} // user notification must not prevent timeout/cleanup
    if (!entered) admission.abort();
    rejectDeadline(deadlineError);
  }, config.functionTimeoutMs);
  try {
    return await runtime.db.transaction(async tx => {
      entered = true;
      checkDeadline();
      let tail = Promise.resolve(), failure;
      const query = (kind, sql, params = []) => {
        if (!accepting) return Promise.reject(new ApplicationError("INVOCATION_CLOSED", 409));
        const work = tail.then(() => {
          if (!open) throw new ApplicationError("INVOCATION_CLOSED", 409);
          checkDeadline();
          return tx[kind](sql, params, {timeoutMs: config.databaseTimeoutMs});
        });
        tail = work.then(() => {}, error => { failure = failure || error; });
        return work;
      };
      // No raw runtime/host API is given to the function. Each call has its own
      // immutable identity and lexical database guard, never a lane-global user.
      const db = Object.freeze({query: (s,p) => query("query",s,p), execute: (s,p) => query("execute",s,p)});
      const context = Object.freeze({
        ...identity, wxContext: identity, requestId: runtime.requestId, laneId: runtime.laneId, dbDriver: config.driver,
        getWXContext: () => identity, signal: signal.signal, db,
      });
      const cleanEvent = {...event};
      for (const key of ["context", "wxContext", "session_key", "userId"]) delete cleanEvent[key];
      for (const [key, value] of Object.entries({
        APPID: identity.APPID, OPENID: identity.OPENID, UNIONID: identity.UNIONID,
        appid: identity.APPID, openid: identity.OPENID, unionid: identity.UNIONID,
      })) cleanEvent[key] = value;
      const body = Promise.resolve().then(() => main(cleanEvent, context)).then(async result => {
        // Include already submitted fire-and-forget statements before commit.
        // Do not permit a detached continuation to submit additional statements.
        accepting = false;
        await tail;
        if (failure) throw failure;
        checkDeadline();
        const serialized = JSON.stringify(result === undefined ? null : result);
        if (serialized === undefined || serialized.length > 1048576) throw Error("invalid function result");
        checkDeadline();
        return JSON.parse(serialized);
      });
      try {
        const result = await Promise.race([body, deadline]);
        checkDeadline();
        // The function has succeeded; COMMIT now owns the outcome. Do not turn
        // a known successful commit into a timeout or attempt to undo it.
        clearTimeout(timer);
        return result;
      } catch (error) {
        // Force the existing facade's awaited rollback path, even if business
        // code throws an Error named TimeoutError, AbortError, or a primitive.
        throw expired ? deadlineError : new ApplicationError("FUNCTION_FAILED", 500);
      } finally { open = false; accepting = false; }
    }, {
      signal: admission.signal,
      timeoutMs: config.functionTimeoutMs + config.databaseTimeoutMs + 5000,
    });
  } catch (error) {
    if (expired) throw deadlineError;
    throw error instanceof ApplicationError ? error : new ApplicationError("FUNCTION_FAILED", 500);
  } finally {
    open = false;
    accepting = false;
    clearTimeout(timer);
    if (pump !== undefined) clearInterval(pump);
    try { signal.abort(); } catch (_) {}
  }
}

export function createApplication(functions, config, {exchangeCode = exchangeWechatCode} = {}) {
  // Explicit allowlist, not a client-selected filesystem path or dynamic import.
  const registry = Object.freeze({...functions});
  return async ctx => {
    ctx.header("cache-control", "no-store");
    const requestId = ctx.runtime.requestId;
    try {
      if (ctx.method !== "POST") throw new ApplicationError("METHOD_NOT_ALLOWED", 405);
      if (ctx.path === "/auth/login") return ctx.json({...await login(ctx, config, exchangeCode), requestId}, 200);
      const match = /^\/functions\/([A-Za-z][A-Za-z0-9_-]{0,63})$/.exec(ctx.path);
      if (!match || !Object.prototype.hasOwnProperty.call(registry, match[1]) || typeof registry[match[1]] !== "function") {
        throw new ApplicationError("FUNCTION_NOT_FOUND", 404);
      }
      const identity = await authenticate(ctx, config);
      const result = await invokeFunction(registry[match[1]], objectBody(ctx), identity, ctx.runtime, config);
      return ctx.json({result: result === undefined ? null : result, requestId}, 200);
    } catch (error) {
      const safe = error instanceof ApplicationError ? error : new ApplicationError("INTERNAL_ERROR", 500);
      return ctx.json({error: {code: safe.code}, requestId}, safe.status);
    }
  };
}
