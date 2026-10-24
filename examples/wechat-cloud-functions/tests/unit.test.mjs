import test from "node:test";
import assert from "node:assert/strict";
import {createApplication, readConfig, invokeFunction, hash} from "../lib/application.mjs";
import clientModule from "../client/vhttpd.js";

const config = readConfig({WECHAT_APP_ID: "test-app", WECHAT_APP_SECRET: "private-secret", WECHAT_FUNCTION_TIMEOUT_MS: "30"});
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const identity = Object.freeze({OPENID: "alice", APPID: "test-app", UNIONID: "", userId: "alice-id"});

function context(path, body = {}, token, db) {
  return {
    path, method: "POST", headers: token ? {authorization: "Bearer " + token} : {},
    runtime: {requestId: "request-test", db}, bodyText: () => JSON.stringify(body),
    header() {}, json: (body, status) => ({body, status}),
  };
}

test("configuration fails closed and tokens are hashed", () => {
  assert.throws(() => readConfig({}));
  assert.throws(() => readConfig({WECHAT_APP_ID: "a", WECHAT_APP_SECRET: "b", WECHAT_DB_DRIVER: "other"}));
  assert.equal(hash("x").length, 64);
  assert.notEqual(hash("test-app:x"), hash("other-app:x"));
});

test("identity and event identity cannot be supplied by clients", async () => {
  const tx = {query: async () => ({rows: []}), execute: async () => ({})};
  const runtime = {requestId: "one", db: {transaction: callback => callback(tx)}};
  const result = await invokeFunction(async (event, ctx) => {
    assert.equal(ctx.OPENID, "alice");
    assert.equal(event.openid, "alice");
    assert.equal(event.APPID, "test-app");
    assert.equal(event.context, undefined);
    assert.equal(event.session_key, undefined);
    assert.ok(Object.isFrozen(ctx) && Object.isFrozen(ctx.wxContext));
    await pause(1);
    assert.strictEqual(ctx.getWXContext(), identity);
    return ctx.OPENID;
  }, {openid: "bob", APPID: "evil", context: {OPENID: "bob"}, session_key: "bad"}, identity, runtime, config);
  assert.equal(result, "alice");
});

test("two concurrent invocations retain separate lexical identities", async () => {
  const db = {transaction: callback => callback({query: async () => ({rows: []}), execute: async () => ({})})};
  const handler = async (_, ctx) => { const before = ctx.OPENID; await pause(5); return [before, ctx.OPENID, ctx.requestId]; };
  const results = await Promise.all(["alice", "bob"].map(name => invokeFunction(handler, {},
    Object.freeze({...identity, OPENID: name}), {db, requestId: name}, config)));
  assert.deepEqual(results, [["alice", "alice", "alice"], ["bob", "bob", "bob"]]);
});

test("failure and deadline await transaction rollback, then deny late SQL", async () => {
  for (const mode of ["error", "timeout"]) {
    let saved, rolledBack = false, executions = 0;
    const runtime = {requestId: mode, db: {transaction: async callback => {
      try { return await callback({execute: async () => { executions++; }, query: async () => ({rows: []})}); }
      catch (error) {
        // Simulate the native facade: ordinary errors await rollback.
        assert.equal(error.name, "CloudInvocationError");
        await pause(10);
        rolledBack = true;
        throw error;
      }
    }}};
    await assert.rejects(invokeFunction(async (_, ctx) => {
      saved = ctx;
      await ctx.db.execute("INSERT");
      if (mode === "error") throw null;
      await new Promise(() => {});
    }, {}, identity, runtime, config), error => error.code === (mode === "error" ? "FUNCTION_FAILED" : "FUNCTION_TIMEOUT"));
    assert.ok(rolledBack);
    await assert.rejects(saved.db.execute("late"), error => error.code === "INVOCATION_CLOSED");
    assert.equal(executions, 1);
  }
});

test("submitted SQL is joined before commit and swallowed failures still roll back", async () => {
  let committed = false, writes = 0;
  const runtime = {db: {transaction: async callback => {
    const value = await callback({execute: async () => { await pause(3); writes++; }});
    assert.equal(writes, 2);
    committed = true;
    return value;
  }}};
  await invokeFunction((_, ctx) => { ctx.db.execute("one"); ctx.db.execute("two"); return 42; }, {}, identity, runtime, config);
  assert.ok(committed);
  runtime.db.transaction = callback => callback({query: async () => { throw Error("sql failure"); }});
  await assert.rejects(invokeFunction(async (_, ctx) => { try { await ctx.db.query("bad"); } catch (_) {} }, {}, identity, runtime, config));
});

test("failed exchange and invalid authentication never run a function or leak secrets", async () => {
  let ran = false;
  const app = createApplication({getUser: () => { ran = true; }}, config, {
    exchangeCode: async () => { throw Error("private-secret session_key code"); },
  });
  const badLogin = await app(context("/auth/login", {code: "x"}));
  assert.equal(badLogin.status, 502);
  assert.ok(!JSON.stringify(badLogin).includes("private-secret"));
  const absent = await app(context("/functions/getUser", {openid: "alice"}));
  assert.equal(absent.status, 401);
  const invalid = await app(context("/functions/getUser", {}, "a".repeat(64), {query: async () => ({rows: []})}));
  assert.equal(invalid.status, 401);
  assert.equal(ran, false);
});

test("an invalid exchange result cannot create a session", async () => {
  const app = createApplication({}, config, {exchangeCode: async () => ({errcode: 40029, openid: "forged", session_key: "secret"})});
  const result = await app(context("/auth/login", {code: "bad"}, undefined, {transaction: () => assert.fail("must not write")}));
  assert.equal(result.status, 401);
});

test("non-serializable results fail inside the transaction boundary", async () => {
  let rolledBack = false;
  const runtime = {db: {transaction: async callback => {
    try { return await callback({}); } catch (error) { rolledBack = true; throw error; }
  }}};
  await assert.rejects(invokeFunction(() => 1n, {}, identity, runtime, config));
  assert.ok(rolledBack);
});

test("finite CPU work past the deadline cannot silently commit", async () => {
  let committed = false;
  const runtime = {db: {transaction: async callback => { const value = await callback({}); committed = true; return value; }}};
  await assert.rejects(invokeFunction(() => {
    const end = Date.now() + 45;
    while (Date.now() < end) {}
    return "too late";
  }, {}, identity, runtime, config), error => error.code === "FUNCTION_TIMEOUT");
  assert.equal(committed, false);
});

test("Mini Program client sends only the session token and never retries writes", async () => {
  let saved, calls = 0;
  const wxApi = {
    login: ({success}) => success({code: "real-login-code"}),
    setStorageSync: (_, value) => { saved = value; }, getStorageSync: () => saved,
    removeStorageSync: () => { saved = undefined; },
    request: request => {
      calls++;
      if (request.url.endsWith("/auth/login")) {
        assert.deepEqual(request.data, {code: "real-login-code"});
        request.success({statusCode: 200, data: {token: "a".repeat(64), expiresAt: Date.now() + 60000}});
      } else {
        assert.equal(request.header.authorization, "Bearer " + "a".repeat(64));
        request.success({statusCode: 401, data: {error: {code: "UNAUTHORIZED"}}});
      }
    },
  };
  const vhttpd = clientModule.createClient({baseURL: "https://api.example.test", wxApi});
  await vhttpd.login();
  await assert.rejects(vhttpd.callFunction({name: "getUser"}), /UNAUTHORIZED/);
  assert.equal(calls, 2);
  assert.equal(saved, undefined);
});

test("vhttpd.callFunction connects directly using wx.request and preserves result", async () => {
  let saved;
  const requests = [];
  // Deliberately no wx.cloud: both login and business calls use wx.request.
  const wxApi = {
    login: ({success}) => success({code: "login-code"}),
    setStorageSync: (_, value) => { saved = value; }, getStorageSync: () => saved,
    removeStorageSync: () => { saved = undefined; },
    request(request) {
      requests.push(request);
      request.success({statusCode: 200, data: request.url.endsWith("/auth/login")
        ? {token: "b".repeat(64), expiresAt: Date.now() + 60000}
        : {result: {user: "alice"}, requestId: "direct-request"}});
    },
  };
  const vhttpd = clientModule.createClient({baseURL: "https://api.example.test", wxApi});
  await vhttpd.login();
  const {result, requestId} = await vhttpd.callFunction({name: "getUser", data: {hello: "world"}});
  assert.deepEqual(result, {user: "alice"});
  assert.equal(requestId, "direct-request");
  assert.deepEqual(requests.map(request => request.url), [
    "https://api.example.test/auth/login", "https://api.example.test/functions/getUser",
  ]);
  assert.equal(requests[1].method, "POST");
  assert.deepEqual(requests[1].data, {hello: "world"});
  assert.equal(requests[1].header.authorization, "Bearer " + "b".repeat(64));
});

function callbackClient(request, session = {token: "c".repeat(64), expiresAt: Date.now() + 60000}) {
  return clientModule.createClient({baseURL: "https://api.example.test", wxApi: {
    getStorageSync: () => session, removeStorageSync() {}, request,
  }});
}

test("success and complete precede Promise resolution and share the returned object", async () => {
  const order = [];
  let successValue, completeValue;
  const vhttpd = callbackClient(request => request.success({statusCode: 200,
    data: {result: {id: "alice"}, requestId: "request-1"}}));
  const promise = vhttpd.callFunction({name: "getUser",
    success(value) { order.push("success"); successValue = value; return "ignored"; },
    fail() { assert.fail("must not fail"); },
    complete(value) { order.push("complete"); completeValue = value; },
  });
  assert.ok(promise instanceof Promise);
  assert.deepEqual(order, []);
  const result = await promise;
  order.push("await");
  assert.deepEqual(order, ["success", "complete", "await"]);
  assert.strictEqual(successValue, result);
  assert.strictEqual(completeValue, result);
  assert.deepEqual(result, {result: {id: "alice"}, requestId: "request-1", errMsg: "callFunction:ok"});
});

test("HTTP, network, invalid name and missing/expired session use fail then complete", async () => {
  const cases = [
    {request: r => r.success({statusCode: 500, data: {error: {code: "FUNCTION_FAILED"}}}),
      message: "FUNCTION_FAILED", status: 500},
    {request: r => r.fail({errMsg: "request:fail timeout", errno: 42}),
      message: "request:fail timeout", errno: 42},
    {name: "../bad", message: "INVALID_FUNCTION_NAME"},
    {session: null, message: "LOGIN_REQUIRED"},
    {session: {token: "expired", expiresAt: 1}, message: "LOGIN_REQUIRED"},
  ];
  for (const scenario of cases) {
    const order = [];
    let failed, completed;
    const request = scenario.request || (() => assert.fail("must not send HTTP"));
    const vhttpd = callbackClient(request, scenario.session);
    const promise = vhttpd.callFunction({name: scenario.name || "getUser",
      success() { assert.fail("must not succeed"); },
      fail(error) { order.push("fail"); failed = error; },
      complete(value) { order.push("complete"); completed = value; },
    });
    await assert.rejects(promise, error => {
      assert.strictEqual(error, failed);
      assert.strictEqual(error, completed);
      assert.equal(error.message, scenario.message);
      assert.equal(error.errMsg, "callFunction:fail " + scenario.message);
      assert.equal(error.status, scenario.status);
      assert.equal(error.errno, scenario.errno);
      return true;
    });
    assert.deepEqual(order, ["fail", "complete"]);
  }
});

test("callback-only callers can ignore rejected Promises, including complete-only calls", async () => {
  for (const failCallback of [false, true]) {
    const order = [];
    await new Promise(resolve => {
      const vhttpd = callbackClient(r => r.fail({errMsg: "request:fail offline"}));
      // Intentionally neither await nor catch the callFunction return value.
      vhttpd.callFunction({name: "getUser",
        ...(failCallback ? {fail() { order.push("fail"); }} : {}),
        complete(error) {
          order.push("complete");
          assert.match(error.errMsg, /offline/);
          resolve();
        },
      });
    });
    // Node's test runner fails the test if a rejection goes unhandled.
    await pause(0);
    assert.deepEqual(order, failCallback ? ["fail", "complete"] : ["complete"]);
  }
});

test("callback exceptions still run complete and never switch success into fail", async () => {
  for (const failure of [false, true]) {
    const callbackError = Error("callback exception");
    const order = [];
    const vhttpd = callbackClient(r => failure ? r.fail(Error("offline"))
      : r.success({statusCode: 200, data: {result: null}}));
    await assert.rejects(vhttpd.callFunction({name: "getUser",
      success() { order.push("success"); throw callbackError; },
      fail() { order.push("fail"); throw callbackError; },
      complete() { order.push("complete"); },
    }), error => error === callbackError);
    assert.deepEqual(order, [failure ? "fail" : "success", "complete"]);
  }
  const vhttpd = callbackClient(r => r.success({statusCode: 200, data: {result: null}}));
  await assert.rejects(vhttpd.callFunction({name: "getUser",
    complete() { throw Error("complete exception"); },
  }), /complete exception/);
});

test("concurrent calls keep callbacks and Promise results isolated and settle only once", async () => {
  const pending = [];
  const vhttpd = callbackClient(request => pending.push(request));
  const order = [];
  const alice = vhttpd.callFunction({name: "getUser", data: {user: "alice"},
    success(res) { order.push(res.result); }, complete() { order.push("alice complete"); }});
  const bob = vhttpd.callFunction({name: "getUser", data: {user: "bob"},
    fail(err) { order.push(err.message); }, complete() { order.push("bob complete"); }});
  pending[1].fail(Error("bob failed"));
  pending[0].success({statusCode: 200, data: {result: "alice"}});
  pending[0].fail(Error("duplicate transport callback"));
  pending[1].success({statusCode: 200, data: {result: "wrong"}});
  assert.equal((await alice).result, "alice");
  await assert.rejects(bob, /bob failed/);
  // Cross-call microtask ordering is not part of the contract; each call's is.
  assert.deepEqual(order.filter(value => value.startsWith("bob")), ["bob failed", "bob complete"]);
  assert.deepEqual(order.filter(value => value.startsWith("alice")), ["alice", "alice complete"]);
});
