import {createCloudInvoker} from '../../examples/wechat-cloud-functions/lib/cloud/runtime.mjs';
import {loadFunctions} from '../../examples/wechat-cloud-functions/lib/cloud/loader.mjs';
const invoke = createCloudInvoker(loadFunctions('tests/relay-db/cloudfunctions'), 'relay-fixture');
const config = {driver: 'mysql', functionTimeoutMs: 5000, databaseTimeoutMs: 30000,
  bodyLimitBytes: 65536, documentLimitBytes: 65536, resultLimitBytes: 1048576};
async function rawDatabase(request) {
  const pump = setInterval(() => globalThis.vhttpdHost.database('__drain'), 5);
  try { return JSON.parse(await globalThis.vhttpdHost.database(JSON.stringify(request))); }
  finally { clearInterval(pump); }
}
export default async ctx => {
  if (ctx.path === '/fixture-ready') return ctx.json({ok: true});
  try {
    if (ctx.path === '/raw-database') {
      const result = await rawDatabase({...JSON.parse(ctx.bodyText('{}')), timeout_ms: 30000});
      return ctx.json(result, result.ok ? 200 : 500);
    }
    if (ctx.path === '/effect') {
      const result = await ctx.runtime.db.execute('UPDATE relay_effects SET n=n+1 WHERE id=1');
      return ctx.json(result, result.ok ? 200 : 500);
    }
    if (ctx.path === '/orphan-begin') {
      // Deliberately omit COMMIT/ROLLBACK to verify the remote idle reaper,
      // independently of the SDK transaction wrapper's own cleanup.
      const send = rawDatabase;
      const begin = await send({op: 'begin', timeout_ms: 1500});
      if (!begin.ok) throw new Error('fixture BEGIN failed');
      const written = await send({op: 'execute', session_id: begin.session_id, timeout_ms: 1000,
        sql: "INSERT INTO wcf_documents VALUES ('relay-fixture','relay-fixture','relay_probe','expired',JSON_OBJECT('_id','expired'))"});
      if (!written.ok) throw new Error('fixture INSERT failed');
      return ctx.json({ok: true});
    }
    if (ctx.path === '/query-write') {
      const result = await ctx.runtime.db.query("INSERT INTO wcf_documents (app_id,env_id,collection_name,doc_id,body) VALUES ('relay-fixture','relay-fixture','relay_probe','query-write',JSON_OBJECT('_id','query-write'))");
      return ctx.json(result, result.ok ? 200 : 500);
    }
    const event = JSON.parse(ctx.bodyText('{}'));
    return ctx.json(await invoke('probe', event,
      {APPID: 'relay-fixture', OPENID: 'fixture-user', UNIONID: ''}, ctx.runtime, config));
  } catch (e) { return ctx.json({error: String(e.message || e)}, 500); }
};
