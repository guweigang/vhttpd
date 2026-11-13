// Run with vjsx --runtime node. No Node executable or node:test/vm dependency.
import fs from 'node:fs';
import '../../admin/ui/relay-config.js';

function assert(value, message) { if (!value) throw new Error(message); }
async function exercise(stale) {
  const elements = new Map(), calls = [];
  const $ = id => {
    if (!elements.has(id)) elements.set(id, {value:'', textContent:'', innerHTML:'', disabled:false,
      classList:{remove(){}}, listeners:{}, addEventListener(event, fn) { this.listeners[event] = fn; }});
    return elements.get(id);
  };
  const main = 'version=2\ninclude=["db.toml"]\n';
  const original = '[resources.db.wechat]\nkind="mysql"\n';
  const files = [{path:'/fixture/main.toml', original:main, value:main+'\n[relays.database]\nmode="agent"\n'},
    {path:'/fixture/db.toml', original:stale?'stale':original, value:original+'options.relay="relay:database"\n'}];
  const workspace = {config_path:'/fixture/main.toml', files:[
    {source:{path:'/fixture/main.toml',role:'main',relay_ids:[]},value:main},
    {source:{path:'/fixture/db.toml',role:'include',relay_ids:[]},value:original}], pipelines:[],adapters:[]};
  const context = {$, RelayConfig:globalThis.RelayConfig, location:{hash:'#relay-draft?id=relay-database-'+ 'a'.repeat(24)},
    crypto:{randomUUID:()=> 'fixture'}, URLSearchParams, asArray:v=>Array.isArray(v)?v:[], esc:v=>String(v??''), table:()=>'',
    ConfigSourceLink:{parse:()=>null}, selectView(){}, refresh:async()=>{}, state:{authRequired:false,data:{configFiles:[]}},
    window:{addEventListener(){}}, apiRequest:async(path, options={}) => {
      calls.push({path,options});
      if (path === '/admin/config/workspace') return workspace;
      if (options.method === 'POST' || path.endsWith('/diff')) return {ok:true,allowed:false,strategy:'restart'};
      return {config_path:workspace.config_path,files};
    }};
  new Function(...Object.keys(context), fs.readFileSync('admin/ui/relay-ui.js','utf8'))(...Object.values(context));
  const settle = async()=> { for(let i=0;i<16;i++) await Promise.resolve(); };
  await settle();
  if (stale) {
    assert($('relayEditError').textContent.includes('项目配置已变化'), 'stale source must fail');
    assert(!calls.some(c=>c.options.method==='POST'), 'stale source must not publish');
    return;
  }
  assert($('relayStage').textContent.includes('远端数据库绑定'), 'database draft must open');
  assert($('relaySource').disabled && $('relayToken').disabled, 'imported bundle must not be edited as a Relay-only form');
  assert(!calls.some(c=>c.options.method==='POST'), 'opening a draft must not publish');
  $('relayValidate').listeners.click(); await settle();
  const saved = calls.find(c=>c.options.method==='POST' && c.path.includes('?id='));
  assert(saved && JSON.stringify(JSON.parse(saved.options.body).files) === JSON.stringify(files), 'all include files must survive validation');
  assert(!$('relayPublish').disabled, 'validated bundle must be publishable');
  $('relayPublish').listeners.click(); await settle();
  assert(calls.some(c=>c.path.endsWith('/publish')), 'publish must use the project changeset');
}
await exercise(false);
await exercise(true);
console.log('PASS Desktop database draft review, multi-file validation, publication and source conflict protection');
