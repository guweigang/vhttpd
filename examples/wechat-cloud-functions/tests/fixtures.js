const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const marker = context => context.dbDriver === "mysql" ? "?" : "$1";

exports.delayedIdentity = async (event, context) => {
  const startedAt = Date.now();
  const before = context.OPENID;
  await pause(60);
  const result = await context.db.query("SELECT open_id, display_name FROM wcf_users WHERE user_id = " + marker(context), [context.userId]);
  return {before, after: context.OPENID, eventOpenid: event.openid, eventAppid: event.APPID,
    hasFakeContext: !!event.context, user: result.rows[0], requestId: context.requestId,
    laneId: context.laneId, startedAt, finishedAt: Date.now()};
};

exports.failure = async (_, context) => {
  await context.db.execute("INSERT INTO wcf_audit (owner) VALUES (" + marker(context) + ")", [context.OPENID]);
  throw Error("PRIVATE_ERROR_MUST_NOT_LEAK");
};

exports.timeout = async (_, context) => {
  await context.db.execute("INSERT INTO wcf_audit (owner) VALUES (" + marker(context) + ")", [context.OPENID]);
  await context.db.query(context.dbDriver === "mysql" ? "SELECT SLEEP(1)" : "SELECT pg_sleep(1)");
};

exports.late = async (_, context) => {
  await pause(1000);
  await context.db.execute("INSERT INTO wcf_audit (owner) VALUES (" + marker(context) + ")", [context.OPENID]);
};

exports.success = async (_, context) => {
  // The adapter must join this submitted write before committing.
  context.db.execute("INSERT INTO wcf_audit (owner) VALUES (" + marker(context) + ")", [context.OPENID]);
  return {openid: context.OPENID};
};
