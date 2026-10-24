const driver = "__DRIVER__";
const sqlSlow = driver === "mysql" ? "SELECT SLEEP(0.3) AS slept" : "SELECT pg_sleep(0.3) AS slept";
const placeholder = driver === "mysql" ? "?" : "$1";
const check = (yes, message) => { if (!yes) throw Error(message); };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const rejects = async (work, name) => {
  try { await work; } catch(e) { if (name) check(e.name === name, `${name}: got ${e.name}: ${e.message}`); return e; }
  throw Error("expected rejection: " + name);
};
globalThis.databaseDetached = "pending";
globalThis.__vhttpd_handle = async ctx => {
  const db = ctx.runtime.db;
  const count = async () => Number((await db.query("SELECT COUNT(*) AS n FROM vjsx_async_items")).rows[0].n);
  if (ctx.path === "/setup") {
    await db.execute("DROP TABLE IF EXISTS vjsx_async_items");
    await db.execute("CREATE TABLE vjsx_async_items (id INTEGER PRIMARY KEY, value VARCHAR(100))");
    return ctx.text("setup-ok");
  }
  if (ctx.path === "/parallel" || ctx.path === "/parallel-shared") {
    let ticked = false;
    setTimeout(() => { ticked = true; }, 15);
    const watchdog = setTimeout(() => {}, 2000);
    const start = Date.now();
    const pending = db.query(sqlSlow);
    check(typeof pending.then === "function", "not a Promise");
    const results = await Promise.all([pending, db.query(sqlSlow)]);
    clearTimeout(watchdog);
    check(ticked, "JS timer starved");
    check(Date.now() - start < (ctx.path === "/parallel" ? 550 : 950), "queries serialized: " + (Date.now() - start));
    console.log(driver + " two 300ms queries: " + (Date.now() - start) + "ms");
    check(results.every(r => r.ok && r.rows.length === 1), "query failed");
    return ctx.text("parallel-ok");
  }
  if (ctx.path === "/transactions") {
    let saved;
    const result = await db.transaction(async tx => {
      saved = tx;
      await tx.execute("INSERT INTO vjsx_async_items VALUES (1, " + placeholder + ")", ["O'Reilly你好"]);
      check((await tx.query("SELECT value FROM vjsx_async_items WHERE id = 1")).rows[0].value === "O'Reilly你好", "params/read-your-writes");
      const start = Date.now();
      await Promise.all([tx.query(sqlSlow), tx.query(sqlSlow)]);
      check(Date.now() - start >= 570, "transaction used concurrent connections");
      return "committed";
    });
    check(result === "committed" && await count() === 1, "commit failed");
    await rejects(saved.query("SELECT 1"));
    await rejects(db.transaction(async tx => { await tx.execute("INSERT INTO vjsx_async_items VALUES (2, 'rollback')"); throw Error("rollback"); }));
    // Failed SQL dooms the transaction even if the callback swallows it.
    await rejects(db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (3, 'doomed')");
      await rejects(tx.query("SELECT * FROM no_such_vjsx_table"));
    }));
    await pause(50);
    check(await count() === 1, "rollback leaked writes");
    await db.transaction(tx => { tx.execute("INSERT INTO vjsx_async_items VALUES (10, 'tracked')"); });
    check(await count() === 2, "unawaited submitted operation was not tracked");
    await db.execute("DELETE FROM vjsx_async_items WHERE id = 10");
    return ctx.text("transactions-ok");
  }
  if (ctx.path === "/cancel-timeout") {
    let start = Date.now();
    await rejects(db.query(sqlSlow, [], {timeoutMs: 40}), "TimeoutError");
    check(Date.now() - start < 220, "timeout not prompt");
    const ctrl = new AbortController();
    start = Date.now();
    const pending = db.query(sqlSlow, [], {signal: ctrl.signal});
    setTimeout(() => ctrl.abort(), 20);
    await rejects(pending, "AbortError");
    check(Date.now() - start < 220, "abort not prompt");
    await rejects(db.execute("INSERT INTO vjsx_async_items VALUES (4, 'preabort')", [], {signal: AbortSignal.abort()}), "AbortError");
    // Both physical connections are still busy. Cancelled waiters must never
    // execute later, when those connections return to the pool.
    await rejects(db.execute("INSERT INTO vjsx_async_items VALUES (5, 'queued')", [], {timeoutMs: 30}), "TimeoutError");
    await pause(380);
    check(await count() === 1, "cancelled SQL entered database later");
    await db.query("SELECT 1");
    return ctx.text("cancel-timeout-ok");
  }
  if (ctx.path === "/transaction-cancel") {
    let called = false;
    await rejects(db.transaction(() => { called = true; }, {signal: AbortSignal.abort()}), "AbortError");
    check(!called, "pre-aborted transaction callback ran");
    const ctrl = new AbortController();
    let active = false;
    const start = Date.now();
    const pending = db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (6, 'abort')");
      active = true;
      setTimeout(() => ctrl.abort(), 20);
      await tx.query(sqlSlow);
    }, {signal: ctrl.signal});
    await rejects(pending, "AbortError");
    check(active && Date.now() - start < 240, "transaction abort not prompt");
    await rejects(db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (7, 'timeout')");
      await tx.query(sqlSlow);
    }, {timeoutMs: 40}), "TimeoutError");
    await pause(380);
    check(await count() === 1, "cancelled transaction committed");
    // An idle callback must also be rolled back when its lifetime expires.
    await rejects(db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (8, 'idle')");
      await new Promise(() => {});
    }, {timeoutMs: 40}), "TimeoutError");
    await pause(50);
    check(await count() === 1, "idle transaction leaked");
    check(await db.transaction(async tx => (await tx.query("SELECT 1 AS n")).rows[0].n) === "1", "pool not reusable");
    // A cancelled per-query signal dooms the enclosing transaction, even when
    // application code catches the inner rejection.
    await rejects(db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (11, 'child')");
      await rejects(tx.query(sqlSlow, [], {signal: AbortSignal.abort()}), "AbortError");
    }), "AbortError");
    await pause(50);
    check(await count() === 1, "child cancellation did not rollback");
    await rejects(db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (12, 'short-query')");
      await rejects(tx.query(sqlSlow, [], {timeoutMs: 40}), "TimeoutError");
    }), "TimeoutError");
    await pause(380);
    check(await count() === 1, "short per-query deadline did not rollback");
    return ctx.text("transaction-cancel-ok");
  }
  if (ctx.path === "/detached") {
    db.query(sqlSlow).then(() => { globalThis.databaseDetached = "done"; }, e => { globalThis.databaseDetached = e.message; });
    return ctx.text("started");
  }
  if (ctx.path === "/bounds") {
    // Keep admission occupied longer than building all 70 JS Promises. A 50ms
    // deadline can expire on early workers before the last call is submitted.
    const blocker = driver === "mysql" ? "SELECT SLEEP(1.5) AS slept" : "SELECT pg_sleep(1.5) AS slept";
    const results = await Promise.allSettled(Array.from({length: 70}, () => db.query(blocker, [], {timeoutMs: 1000})));
    check(results.every(r => r.status === "rejected"), "unexpected query success");
    check(results.some(r => r.reason.message === "database_busy_or_closed"), "worker limit not enforced");
    await pause(1600);
    await db.query("SELECT 1");
    return ctx.text("bounds-ok");
  }
  if (ctx.path === "/close") {
    db.transaction(async tx => {
      await tx.execute("INSERT INTO vjsx_async_items VALUES (9, 'close')");
      globalThis.databaseDetached = "inflight";
      await tx.query(sqlSlow);
    }).catch(() => {});
    await pause(30);
    return ctx.text("closing");
  }
  return ctx.text(globalThis.databaseDetached);
};
