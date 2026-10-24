const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
require('../../admin/ui/relay-config.js');

function fixture(stale = false) {
  const elements = new Map(), calls = [];
  const $ = id => {
    if (!elements.has(id)) elements.set(id, {value:'',textContent:'',innerHTML:'',classList:{remove(){}},listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}});
    return elements.get(id);
  };
  const main = 'version=2\ninclude=["relay.toml"]\n', include = '# shared relay destination\n';
  const profile = '\n[relays.shared_123]\nmode="agent"\ncarrier="websocket"\nurl="wss://hub.example/relay"\nnode_id="project-unique"\ntoken="private-token"\nautostart=false\n';
  const workspace = {config_path:'/project/main.toml',files:[{source:{path:'/project/main.toml',role:'main',relay_ids:[]},value:main},{source:{path:'/project/relay.toml',role:'include',include_path:'relay.toml',relay_ids:[]},value:include}],pipelines:[],adapters:[]};
  const context = { $, RelayConfig:globalThis.RelayConfig, location:{hash:'#relay-draft?id=shared-relay-'+ 'a'.repeat(24)},
    crypto:require('node:crypto').webcrypto, URLSearchParams, TextEncoder, asArray:v=>Array.isArray(v)?v:[], esc:v=>String(v??''), table:()=>'',
    ConfigSourceLink:{parse:()=>null}, selectView(){}, refresh:async()=>{}, state:{authRequired:false,data:{configFiles:[]}},
    window:{addEventListener(){}}, apiRequest:async(path,options={})=> {
      calls.push({path,options});
      if(path==='/admin/config/workspace') return structuredClone(workspace);
      if(options.method==='POST' && path.startsWith('/admin/config/changesets?id=')) return {ok:true};
      if(path.endsWith('/validate')) return {ok:true};
      if(path.endsWith('/diff')) return {allowed:false,strategy:'restart'};
      if(path.endsWith('/publish')) return {ok:true};
      return {config_path:workspace.config_path,files:[{path:'/project/main.toml',original:stale?'changed':main,value:main+profile}]};
    }};
  vm.runInNewContext(fs.readFileSync(require.resolve('../../admin/ui/relay-ui.js'),'utf8'), context);
  return {$,calls};
}
const settle = async()=>{ for(let i=0;i<8;i++) await new Promise(setImmediate); };

test('shared relay stays a draft and survives selecting a different include before project validation/publication',async()=>{
  const {$,calls}=fixture(); await settle();
  assert.equal($('relayToken').value,'private-token');
  assert.equal($('relayNode').value,'project-unique');
  assert.equal($('relayAutostart').value,'false');
  assert.match($('relayStage').textContent,/尚未发布/);
  assert(!calls.some(c=>c.options.method==='POST'));
  $('relaySource').value='/project/relay.toml';
  await $('relaySource').listeners.change(); await settle();
  assert.equal($('relayToken').value,'private-token');
  await $('relayValidate').listeners.click(); await settle();
  const saved=calls.find(c=>c.options.method==='POST' && c.path.includes('?id='));
  const bundle=JSON.parse(saved.options.body);
  assert.equal(bundle.config_path,'/project/main.toml');
  assert.equal(bundle.files.length,1);
  assert.equal(bundle.files[0].path,'/project/relay.toml');
  assert.equal(bundle.files[0].original,'# shared relay destination\n');
  assert.match(bundle.files[0].value,/private-token/);
  await $('relayPublish').listeners.click(); await settle();
  assert(calls.some(c=>c.path.endsWith('/publish')));
  assert(calls.every(c=>!c.path.includes('private-token')));
});

test('a stale project source never silently imports the shared connection',async()=>{
  const {$,calls}=fixture(true); await settle();
  assert.match($('relayEditError').textContent,/项目配置已变化/);
  assert.notEqual($('relayToken').value,'private-token');
  assert(!calls.some(c=>c.options.method==='POST'));
});
