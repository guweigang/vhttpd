const test=require('node:test'), assert=require('node:assert/strict');
require('../../admin/ui/relay-config.js');require('../../admin/ui/common-config.js');
const C=globalThis.CommonConfig;
function fixture() { return {config_path:'/p/main.toml',files:[
  {source:{path:'/p/main.toml'},value:'version=2\ninclude=["http.toml","app.toml"]\n[control]\nlistener="listener:admin"\ntoken="keep-secret"\n[listeners.admin]\nprotocol="http"\nport=9999\n'},
  {source:{path:'/p/http.toml'},value:'# preserve me\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=8000 # local\n\n[[pipelines]]\nid="hello"\ningress="listener:web"\negress="adapter:app"\nmatch.paths=[\'/hello\', \'/with,comma\',]\nmatch.methods=["GET"]\npolicies=["policy:limits"]\n'},
  {source:{path:'/p/app.toml'},value:'[engines.app]\nkind="vjsx"\nentry="main.mjs"\nthread_count=2\ncustom="""keep\nmultiline\n"""\n[adapters.app]\nkind="http-handler"\nengine="engine:app"\n'}
],pipelines:[{id:'hello',source_path:'/p/http.toml',ingress:'listener:web',egress:'adapter:app'}],adapters:[{id:'app',source_path:'/p/app.toml'}]}; }
test('forms identify cross-include sources and exclude the control listener',()=>{
 const w=fixture(),m=C.inspect(w); assert.deepEqual(m.items.map(i=>[i.type,i.path]),[['listener','/p/http.toml'],['route','/p/http.toml'],['engine','/p/app.toml'],['adapter','/p/app.toml']]);
 assert.deepEqual(m.items[1].values['match.paths'],['/hello','/with,comma']);assert(m.items.every(i=>!i.error));
 assert.deepEqual(C.edit(w,m,Object.fromEntries(m.items.map((i,n)=>[n,i.values]))),[]);
});
test('edits preserve unrelated TOML, comments, capabilities and secrets',()=>{
 const w=fixture(),m=C.inspect(w), edits={0:{port:8001},1:{'match.paths':['/new'],'match.methods':[]},2:{entry:'next.mjs',module_root:'./lib'}};
 const files=C.edit(w,m,edits);assert.equal(files.length,2);
 for(const file of files)assert.equal(file.original,w.files.find(f=>f.source.path===file.path).value);assert(!files.some(f=>f.path===w.config_path));
 assert.match(files[0].value,/port = 8001 # local/);assert.match(files[0].value,/policies=\["policy:limits"\]/);assert(!files[0].value.includes('match.methods'));
 assert.match(files[1].value,/thread_count=2\ncustom="""keep\nmultiline\n"""/);assert.match(files[1].value,/entry = "next.mjs"/);
});
test('reject invalid ports and fields; complex nested match remains source editable',()=>{
 const w=fixture(),m=C.inspect(w); for(const port of [0,65536,1.5,NaN])assert.throws(()=>C.edit(w,m,{0:{port}}));
 assert.throws(()=>C.edit(w,m,{2:{kind:'php'}}));assert.throws(()=>C.edit(w,m,{2:{entry:''}}));
 w.files[1].value+='[pipelines.match]\npaths=["/nested"]\n';const nested=C.inspect(w);assert.match(nested.items[1].error,/嵌套/);
 assert.throws(()=>C.edit(w,nested,{1:{egress:'adapter:other'}}));
});
test('literal strings, multiline arrays and quoted component IDs survive',()=>{
 const w=fixture();w.files[1].value=w.files[1].value.replace('[listeners.web]','[listeners."web"]');
 w.files[1].value=w.files[1].value.replace('["GET"]','[\n"GET",\n"POST",\n]');
 const m=C.inspect(w);assert.deepEqual(m.items[1].values['match.methods'],['GET','POST']);assert.equal(m.items[0].id,'web');
});

test('dynamic management references stay in advanced editing; unspecified host is not invented',()=>{
 const w=fixture();w.files[1].value=w.files[1].value.replace('host="127.0.0.1"\n','');
 assert.equal(C.inspect(w).items[0].values.host,'');
 w.files[0].value=w.files[0].value.replace('listener:admin','${env.ADMIN_LISTENER}');
 const m=C.inspect(w);assert(m.items.filter(i=>i.type==='listener').every(i=>i.error));assert(!m.items.some(i=>i.type==='route'));assert(m.items.some(i=>i.type==='engine' && !i.error));
});
test('new listeners and routes select independent source files and insert before an existing route',()=>{
 const w=fixture(),m=C.inspect(w);
 const listener=C.create(w,m,'listener','/p/app.toml');m.items.push(listener);const li=m.items.length-1;
 listener.id='extra.http';
 const route=C.create(w,m,'route','/p/http.toml');m.items.push(route);const ri=m.items.length-1;
 route.id='health';
 const changes=C.edit(w,m,{[li]:{port:8100},[ri]:{ingress:'listener:extra.http','match.paths':['/health']}});
 assert.equal(changes.length,2);
 const http=changes.find(f=>f.path==='/p/http.toml').value;
 assert(http.indexOf('id = "health"') < http.indexOf('id="hello"'));
 assert.match(http,/ingress = "listener:extra.http"/);
 assert.match(changes.find(f=>f.path==='/p/app.toml').value,/\["listeners"\."extra.http"\]/);
 assert(changes.every(f=>f.original===w.files.find(s=>s.source.path===f.path).value));
});
test('new IDs are unique across includes including hidden management listeners and non-HTTP pipelines',()=>{
 const w=fixture(),m=C.inspect(w),item=C.create(w,m,'listener','/p/http.toml');m.items.push(item);
 item.id='admin';assert.throws(()=>C.edit(w,m,{}),/已在项目中使用/);
 item.id='web';assert.throws(()=>C.edit(w,m,{}),/已在项目中使用/);
 item.id='valid';item.path='/outside.toml';assert.throws(()=>C.edit(w,m,{}),/来源文件/);
});
test('listener deletion previews current cross-file route bindings and blocks dangling references',()=>{
 const w=fixture(),m=C.inspect(w);const l=m.items.findIndex(i=>i.type==='listener'),r=m.items.findIndex(i=>i.type==='route');
 const impact=C.deletionImpact(w,m,l);assert.equal(impact.bindings[0].id,'hello');assert.deepEqual(impact.cascadeIndices,[r]);
 m.items[l].deleted=true;assert.throws(()=>C.edit(w,m,{}),/处理受影响/);
 m.items[r].deleted=true;
 const changes=C.edit(w,m,{});assert.equal(changes.length,1);assert(!changes[0].value.includes('[listeners.web]'));assert(!changes[0].value.includes('[[pipelines]]'));assert.match(changes[0].value,/# preserve me/);
 // Undo is entirely in-memory; the original source has not changed.
 m.items[l].deleted=false;m.items[r].deleted=false;assert.deepEqual(C.edit(w,m,{}),[]);
});
test('rerouting a route removes its old deletion dependency and keeps unrelated source comments',()=>{
 const w=fixture(),m=C.inspect(w);w.files[1].value+='\n# belongs to the following adapter\n[adapters.spare]\nkind="fixed-response"\n';
 const l=m.items.findIndex(i=>i.type==='listener'),r=m.items.findIndex(i=>i.type==='route');
 const edits={[r]:{ingress:'listener:replacement'}};
 assert.equal(C.deletionImpact(w,m,l,edits).references.length,0);assert.equal(C.deletionImpact(w,m,l,edits).bindings.length,0);
 m.items[l].deleted=true;const changes=C.edit(w,m,edits);assert.match(changes[0].value,/ingress = "listener:replacement"/);
 m.items[l].deleted=false;m.items[r].deleted=true;const removed=C.edit(w,m,{});assert.match(removed[0].value,/# belongs to the following adapter\n\[adapters.spare\]/);
});
test('references outside HTTP routes block cascades and report location without exposing values',()=>{
 const w=fixture();w.files[2].value+='\n[adapters.special]\nkind="custom"\noptions.listener="listener:web"\n';
 const m=C.inspect(w),l=m.items.findIndex(i=>i.type==='listener');const impact=C.deletionImpact(w,m,l);
 assert.equal(impact.blockers.length,1);assert.equal(impact.blockers[0].path,'/p/app.toml');assert.equal(impact.blockers[0].field,'options.listener');
 m.items[l].deleted=true;for(const r of impact.cascadeIndices)m.items[r].deleted=true;
 assert.throws(()=>C.edit(w,m,{}),/处理受影响/);
});
test('listener nested settings are removed together, while route inbound references block deletion',()=>{
 const w=fixture();w.files[2].value+='\n[listeners.web.tls]\nenabled=true\n';
 const m=C.inspect(w);for(const item of m.items)if(['listener','route'].includes(item.type))item.deleted=true;
 const changes=C.edit(w,m,{});assert.equal(changes.length,2);assert(!changes.find(f=>f.path==='/p/app.toml').value.includes('listeners.web.tls'));
 const other=fixture();other.files[2].value+='\n[adapters.router]\nkind="custom"\noptions.target="pipeline:hello"\n';
 const n=C.inspect(other),r=n.items.findIndex(i=>i.type==='route');assert.equal(C.deletionImpact(other,n,r).blockers.length,1);
 n.items[r].deleted=true;assert.throws(()=>C.edit(other,n,{}),/处理受影响/);
});
test('new staged components can be cancelled together without writing any configuration',()=>{
 const w=fixture(),m=C.inspect(w);const l=C.create(w,m,'listener','/p/http.toml');m.items.push(l);
 const r=C.create(w,m,'route','/p/app.toml');r.values.ingress='listener:'+l.id;m.items.push(r);
 l.deleted=true;assert.throws(()=>C.edit(w,m,{}),/处理受影响/);
 r.deleted=true;assert.deepEqual(C.edit(w,m,{}),[]);
});

test('new routes default to the latest staged listener and suggested ports avoid existing declarations',()=>{
 const w=fixture(),m=C.inspect(w);const first=C.create(w,m,'listener','/p/http.toml');m.items.push(first);
 const second=C.create(w,m,'listener','/p/app.toml');m.items.push(second);assert.notEqual(first.values.port,second.values.port);
 const route=C.create(w,m,'route','/p/http.toml');assert.equal(route.values.ingress,'listener:'+second.id);
 second.deleted=true;assert.equal(C.create(w,m,'route','/p/http.toml').values.ingress,'listener:'+first.id);
});

test('vjsx and Adapter additions bind across sources, preserve advanced settings and reserve all IDs',()=>{
 const w=fixture(),m=C.inspect(w);
 w.files[0].value+='\n[engines.vjsx1]\nkind="php-cgi"\n[adapters.out1]\nkind="upload"\n';
 const engine=C.create(w,m,'engine','/p/http.toml');assert.equal(engine.id,'vjsx2');m.items.push(engine);
 const adapter=C.create(w,m,'adapter','/p/app.toml');assert.equal(adapter.id,'out2');assert.equal(adapter.values.engine,'engine:vjsx2');m.items.push(adapter);
 const route=C.create(w,m,'route','/p/main.toml');assert.equal(route.values.egress,'adapter:out2');m.items.push(route);
 const files=C.edit(w,m,{});assert.equal(files.length,3);
 assert.match(files.find(f=>f.path==='/p/http.toml').value,/runtime_profile = "script"/);
 assert.match(files.find(f=>f.path==='/p/app.toml').value,/engine = "engine:vjsx2"/);
 adapter.id='app';assert.throws(()=>C.edit(w,m,{}),/ID 已/);
});
test('Adapter kinds use supported schemas and reject invalid fixed-response status',()=>{
 const w=fixture(),m=C.inspect(w),a=C.create(w,m,'adapter','/p/app.toml');m.items.push(a);const index=m.items.length-1;
 for(const kind of ['static','fixed-response','relay-delivery']) {
  C.setAdapterKind(a,kind);const values=kind==='relay-delivery'?{'options.target':'remote'}:{};
  const changed=C.edit(w,m,{[index]:values});assert.match(changed[0].value,new RegExp('kind = "'+kind+'"'));
 }
 C.setAdapterKind(a,'fixed-response');assert.throws(()=>C.edit(w,m,{[index]:{'options.status':'999'}}),/状态码/);
 assert.throws(()=>C.setAdapterKind(a,'unknown'));
});
test('engine deletion lists transitive routes and requires removing or rebinding every adapter and transform',()=>{
 const w=fixture(),m=C.inspect(w),ei=m.items.findIndex(i=>i.type==='engine'),ai=m.items.findIndex(i=>i.type==='adapter');
 let impact=C.deletionImpact(w,m,ei);assert.equal(impact.blockers[0].component,'adapter:app');assert.equal(impact.bindings[0].id,'hello');
 m.items[ei].deleted=true;assert.throws(()=>C.edit(w,m,{}),/处理受影响/);
 impact=C.deletionImpact(w,m,ai);assert.deepEqual(impact.cascadeIndices,[1]);m.items[ai].deleted=true;m.items[1].deleted=true;
 const files=C.edit(w,m,{});assert.equal(files.length,2);assert(!files.some(f=>f.value.includes('[engines.app]') || f.value.includes('[adapters.app]')));
 w.files[0].value+='\n[transforms.shared]\nkind="vjsx"\nengine="engine:app"\n';
 impact=C.deletionImpact(w,m,ei);assert(impact.blockers.some(r=>r.component==='transforms.shared'));assert.throws(()=>C.edit(w,m,{}));
});
test('staged bindings are used for dependency checks, including newly introduced fields',()=>{
 const w=fixture(),m=C.inspect(w),ei=m.items.findIndex(i=>i.type==='engine'),ai=m.items.findIndex(i=>i.type==='adapter');
 assert.equal(C.deletionImpact(w,m,ei,{[ai]:{engine:'engine:other'}}).references.length,0);
 const engine=C.create(w,m,'engine','/p/http.toml');m.items.push(engine);
 const impact=C.deletionImpact(w,m,m.items.length-1,{[ai]:{engine:'engine:'+engine.id}});assert.equal(impact.blockers.length,1);assert.equal(impact.bindings.length,1);
});
test('shared non-HTTP bindings block Adapter cascade; nested and cross-source extensions are removed together',()=>{
 const w=fixture();w.files[0].value+='\n[adapters.app.options]\nsecret="keep-secret"\n[[pipelines]]\nid="relay-in"\ningress="relay:edge"\negress="adapter:app"\n';
 w.pipelines.push({id:'relay-in',source_path:w.config_path,ingress:'relay:edge',egress:'adapter:app'});
 const m=C.inspect(w),ai=m.items.findIndex(i=>i.type==='adapter'),impact=C.deletionImpact(w,m,ai);
 assert(impact.blockers.some(r=>r.component==='relay-in'));assert.equal(impact.bindings.length,2);assert(!JSON.stringify(impact).includes('keep-secret'));
 w.files[0].value=w.files[0].value.split('[[pipelines]]')[0];w.pipelines.pop();
 m.items[ai].deleted=true;m.items[1].deleted=true;
 const files=C.edit(w,m,{});assert(!files.some(f=>f.value.includes('[adapters.app')));assert(files.some(f=>f.path===w.config_path));
});
test('dynamic engine references are guarded and malformed editable layouts still allow safe whole-component deletion',()=>{
 const w=fixture();w.files[2].value=w.files[2].value.replace('engine="engine:app"','engine="${env.APP_ENGINE}"');
 let m=C.inspect(w),ei=m.items.findIndex(i=>i.type==='engine');assert.equal(C.deletionImpact(w,m,ei).blockers.length,1);
 w.files[2].value=w.files[2].value.replace('[adapters.app]\nkind="http-handler"\nengine="${env.APP_ENGINE}"','[adapters.app]\nkind="fixed-response"\n[adapters.app.options]\nstatus="200"\nbody="OK"');
 m=C.inspect(w);const ai=m.items.findIndex(i=>i.type==='adapter');assert(m.items[ai].error);assert(m.items[ai].canDelete);
 m.items[ai].deleted=true;m.items[1].deleted=true;assert(!C.edit(w,m,{}).some(f=>f.value.includes('[adapters.app')));
});

test('engine impact follows transform bindings to pipelines without automatic cascade',()=>{
 const w=fixture();w.files[0].value+='\n[transforms.shared]\nkind="vjsx"\nengine="engine:app"\n';
 w.files[1].value+='transforms=["transform:shared"]\n';
 const m=C.inspect(w),ei=m.items.findIndex(i=>i.type==='engine'),ai=m.items.findIndex(i=>i.type==='adapter');
 const impact=C.deletionImpact(w,m,ei,{[ai]:{engine:'engine:other'}});
 assert.equal(impact.bindings[0].id,'hello');assert(impact.blockers.some(r=>r.component==='transforms.shared'));assert.equal(impact.cascadeIndices.length,0);
});
