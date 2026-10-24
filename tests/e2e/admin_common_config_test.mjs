import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import '../../admin/ui/relay-config.js';
import '../../admin/ui/common-config.js';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
async function port() { const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p; }
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const publicRequest=url=>fetch(url,{headers:{connection:'close'},signal:AbortSignal.timeout(3000)});
async function until(fn,timeout=20000) { let last;const end=Date.now()+timeout;while(Date.now()<end){try{if(await fn())return;}catch(e){last=e;}await pause(100);}throw last || Error('Timed out'); }
test('common HTTP, route and vjsx forms publish cross-include changes and take effect after restart',{timeout:300000},async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-common-config-'));
 const root=path.join(dir,'vhttpd.toml'), listener=path.join(dir,'http.toml'), routes=path.join(dir,'routes.toml'), app=path.join(dir,'app.toml');
 const web=await port(),admin=await port();let next=await port();while([web,admin].includes(next))next=await port();
 const token='common-config-local-test';let child;let logs='';let phase='initial';let starts=0;let failure;
 const entry=fs.readFileSync(path.join(repo,'tests/e2e/fixtures/common-config-main.mjs'),'utf8');
 fs.writeFileSync(path.join(dir,'main.mjs'),entry);fs.writeFileSync(path.join(dir,'next.mjs'),entry.replaceAll('hello-vjsx','common-form-updated'));
 const original=`version=2\ninclude=["http.toml","routes.toml","app.toml"]\n[server]\npid_file="${dir}/runtime.pid"\n[observability]\nevent_log="${dir}/events.ndjson"\n[control]\nlistener="listener:admin"\ntoken="${token}"\n[listeners.admin]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=${admin}\n`;
 fs.writeFileSync(root,original);
 fs.writeFileSync(listener,`# Listener source stays here.\n[listeners.web]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=${web}\n`);
 fs.writeFileSync(routes,'[[pipelines]]\nid="hello"\ningress="listener:web"\nmatch.paths=["/hello"]\nmatch.methods=["GET"]\negress="adapter:app"\n');
 fs.writeFileSync(app,'[engines.app]\nkind="vjsx"\nentry="main.mjs"\nruntime_profile="script"\nthread_count=1\n[adapters.app]\nkind="http-handler"\nengine="engine:app"\n');
 const request=async(url,options={})=>{const r=await fetch(`http://127.0.0.1:${admin}`+url,{...options,headers:{connection:'close','x-vhttpd-admin-token':token,...options.headers},signal:AbortSignal.timeout(3000)});const value=await r.json();if(!r.ok)throw Error(JSON.stringify(value));return value;};
 async function start(){ child=spawn(process.env.VHTTPD_BIN || path.join(repo,'vhttpd'),['--config',root],{cwd:dir,stdio:['ignore','pipe','pipe']});child.stdout.on('data',d=>{logs=(logs+d).slice(-16000);});child.stderr.on('data',d=>{logs=(logs+d).slice(-16000);});await until(async()=>{if(child.exitCode!==null || child.signalCode!==null)throw Error('instance exited');return (await request('/admin/runtime')).schema_version===2 || !!(await request('/admin/config/workspace')).files;},90000);const first=starts++===0;/* A listener can initialize multiple engine sessions serially. */await until(async()=>{const response=await publicRequest(`http://127.0.0.1:${first?web:next}/${first?'hello':'updated'}`);const body=await response.text();return response.status===200 && body.length>0;},90000);process.stderr.write('Ready '+starts+' ('+phase+')\n'); }
 async function stop(){if(child && child.exitCode===null && child.signalCode===null){const done=new Promise(r=>child.once('exit',r));child.kill('SIGTERM');let forced=false;const force=setTimeout(()=>{forced=true;child.kill('SIGKILL');},15000);try{await done;}finally{clearTimeout(force);}if(forced)throw Error('Owned test instance did not shut down within 15 seconds');}}
 try {
  await start();
  const workspace=await request('/admin/config/workspace'),model=CommonConfig.inspect(workspace),edits={};
  for(const [i,item] of model.items.entries()) edits[i]=item.type==='listener'?{host:'127.0.0.1',port:next}:item.type==='route'?{'match.paths':['/updated'],'match.methods':['GET','POST']}:item.type==='engine'?{entry:'next.mjs',module_root:'.'}:{};
  const changes=CommonConfig.edit(workspace,model,edits);assert.equal(changes.length,3);
  const bad=changes.map(f=>({...f,value:f.path===routes?f.value.replace('adapter:app','adapter:missing'):f.value}));
  async function save(id,files){return request('/admin/config/changesets?id='+id,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({config_path:root,files})});}
  await save('invalid-common',bad);await assert.rejects(request('/admin/config/changesets/invalid-common/validate',{method:'POST'}),/unresolved_ref/);
  assert.equal(fs.readFileSync(listener,'utf8'),workspace.files.find(f=>f.source.path===listener).value);
  await save('common',changes);assert.equal((await request('/admin/config/changesets/common/validate',{method:'POST'})).ok,true);
  const appOriginal=fs.readFileSync(app,'utf8');
  fs.writeFileSync(app,appOriginal+'# external edit\n');
  await assert.rejects(request('/admin/config/changesets/common/publish',{method:'POST'}),/source_changed/);
  assert.equal(fs.readFileSync(listener,'utf8'),workspace.files.find(f=>f.source.path===listener).value);
  fs.writeFileSync(app,appOriginal);
  const result=await request('/admin/config/changesets/common/publish',{method:'POST'});assert.equal(result.paths.length,3);assert.equal(fs.readFileSync(root,'utf8'),original);
  const pending=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert(pending.actions.length>0 || !pending.allowed);
  for(const f of changes)assert.equal(fs.readFileSync(f.path,'utf8'),f.value);
  await stop();await start();
  await until(async()=>{const r=await publicRequest(`http://127.0.0.1:${next}/updated`);return r.status===200 && (await r.text()).includes('common-form-updated');});
  const effective=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert.equal(effective.allowed,true);assert.equal(effective.actions.length,0);
  phase='adding';
  // Add an HTTP listener and its route in different include files.
  const addedPort=await port();
  const addWorkspace=await request('/admin/config/workspace'),addModel=CommonConfig.inspect(addWorkspace);
  const addedListener=CommonConfig.create(addWorkspace,addModel,'listener',listener);addedListener.id='extra';addModel.items.push(addedListener);
  const listenerIndex=addModel.items.length-1;
  const addedRoute=CommonConfig.create(addWorkspace,addModel,'route',routes);addedRoute.id='extra-route';addModel.items.push(addedRoute);
  const routeIndex=addModel.items.length-1;
  const addedChanges=CommonConfig.edit(addWorkspace,addModel,{[listenerIndex]:{port:addedPort},[routeIndex]:{ingress:'listener:extra','match.paths':['/added']}});
  assert.equal(addedChanges.length,2);
  await save('add-http',addedChanges);assert.equal((await request('/admin/config/changesets/add-http/validate',{method:'POST'})).ok,true);
  await request('/admin/config/changesets/add-http/publish',{method:'POST'});
  const addedPending=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert(addedPending.actions.length || !addedPending.allowed);
  await stop();await start();
  await until(async()=>{const r=await publicRequest(`http://127.0.0.1:${addedPort}/added`);return r.status===200 && (await r.text()).includes('common-form-updated');});
  phase='removing';
  // Preview the binding, explicitly stage its cascade, then remove both sources.
  const removeWorkspace=await request('/admin/config/workspace'),removeModel=CommonConfig.inspect(removeWorkspace);
  const removeListener=removeModel.items.findIndex(i=>i.type==='listener' && i.id==='extra');
  const impact=CommonConfig.deletionImpact(removeWorkspace,removeModel,removeListener);
  assert.equal(impact.bindings[0].id,'extra-route');assert.equal(impact.blockers.length,0);assert.equal(impact.cascadeIndices.length,1);
  removeModel.items[removeListener].deleted=true;
  assert.throws(()=>CommonConfig.edit(removeWorkspace,removeModel,{}),/处理受影响/);
  for(const i of impact.cascadeIndices)removeModel.items[i].deleted=true;
  const removedChanges=CommonConfig.edit(removeWorkspace,removeModel,{});assert.equal(removedChanges.length,2);
  await save('remove-http',removedChanges);assert.equal((await request('/admin/config/changesets/remove-http/validate',{method:'POST'})).ok,true);
  await request('/admin/config/changesets/remove-http/publish',{method:'POST'});
  const removedPending=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert(removedPending.actions.length || !removedPending.allowed);
  await stop();await start();
  const removedEffective=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert.equal(removedEffective.allowed,true);assert.equal(removedEffective.actions.length,0);
  await until(async()=>{const r=await publicRequest(`http://127.0.0.1:${next}/updated`);return r.status===200;});
  await assert.rejects(fetch(`http://127.0.0.1:${addedPort}/added`,{signal:AbortSignal.timeout(2000)}));
  assert.equal(fs.readFileSync(root,'utf8'),original);
  assert(!fs.readFileSync(routes,'utf8').includes('extra-route'));
  assert(!fs.readFileSync(listener,'utf8').includes('"extra"'));

  phase='adding-engine-adapter';
  // Module initialization may outlive the hook budget (compiler load + top-level code).
  fs.writeFileSync(path.join(dir,'slow.mjs'),'const readyAt=Date.now()+11000; while(Date.now()<readyAt) {}\n'+entry.replaceAll('hello-vjsx','slow-vjsx'));
  // One project changeset creates an engine, an outlet and its route in three includes.
  const ew=await request('/admin/config/workspace'),em=CommonConfig.inspect(ew);
  const engine=CommonConfig.create(ew,em,'engine',listener);engine.id='extra-vjsx';engine.values.entry='slow.mjs';em.items.push(engine);
  const outlet=CommonConfig.create(ew,em,'adapter',app);outlet.id='extra-out';em.items.push(outlet);
  assert.equal(outlet.values.engine,'engine:extra-vjsx');
  const er=CommonConfig.create(ew,em,'route',routes);er.id='extra-vjsx-route';er.values['match.paths']=['/extra-vjsx'];em.items.push(er);
  assert.equal(er.values.egress,'adapter:extra-out');
  fs.writeFileSync(path.join(dir,'asset.txt'),'static outlet works');
  for(const [kind,id,url] of [['fixed-response','reply','/reply'],['static','assets','/asset.txt']]) {
   const a=CommonConfig.create(ew,em,'adapter',app);CommonConfig.setAdapterKind(a,kind);a.id=id;if(kind==='static')a.values.root=dir;else {a.values['options.status']='201';a.values['options.body']='form-created';}em.items.push(a);
   const r=CommonConfig.create(ew,em,'route',routes);r.id=id+'-route';r.values['match.paths']=[url];em.items.push(r);
  }
  const ec=CommonConfig.edit(ew,em,{});assert.equal(ec.length,3);
  await save('add-engine-outlet',ec);assert.equal((await request('/admin/config/changesets/add-engine-outlet/validate',{method:'POST'})).ok,true);
  await request('/admin/config/changesets/add-engine-outlet/publish',{method:'POST'});
  const ep=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert(ep.actions.length || !ep.allowed);
  await stop();await start();
  await until(async()=>{const r=await publicRequest(`http://127.0.0.1:${next}/extra-vjsx`);return r.status===200 && (await r.text()).includes('slow-vjsx');});
  phase='fixed-response-request';
  const fixed=await publicRequest(`http://127.0.0.1:${next}/reply`);assert.equal(fixed.status,201);assert.equal(await fixed.text(),'form-created');
  phase='static-request';
  const asset=await publicRequest(`http://127.0.0.1:${next}/asset.txt`);assert.equal(asset.status,200);assert.equal(await asset.text(),'static outlet works');
  assert(!logs.includes('lane_warmup_timeout') && !logs.includes('lane_bootstrap_timeout'));
  const ee=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert.equal(ee.allowed,true);assert.equal(ee.actions.length,0);
  phase='removing-engine-adapter';
  const dw=await request('/admin/config/workspace'),dm=CommonConfig.inspect(dw);
  const di=dm.items.findIndex(i=>i.type==='engine' && i.id==='extra-vjsx'),da=dm.items.findIndex(i=>i.type==='adapter' && i.id==='extra-out');
  const de=CommonConfig.deletionImpact(dw,dm,di);assert.equal(de.blockers.length,1);assert.equal(de.bindings[0].id,'extra-vjsx-route');
  dm.items[di].deleted=true;assert.throws(()=>CommonConfig.edit(dw,dm,{}),/处理受影响/);
  const ad=CommonConfig.deletionImpact(dw,dm,da);assert.equal(ad.cascadeIndices.length,1);assert.equal(ad.blockers.length,0);
  dm.items[da].deleted=true;for(const i of ad.cascadeIndices)dm.items[i].deleted=true;
  for(const item of dm.items)if((item.type==='adapter' && ['reply','assets'].includes(item.id)) || (item.type==='route' && ['reply-route','assets-route'].includes(item.id)))item.deleted=true;
  const dc=CommonConfig.edit(dw,dm,{});assert.equal(dc.length,3);
  await save('remove-engine-outlet',dc);assert.equal((await request('/admin/config/changesets/remove-engine-outlet/validate',{method:'POST'})).ok,true);
  await request('/admin/config/changesets/remove-engine-outlet/publish',{method:'POST'});
  const dp=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert(dp.actions.length || !dp.allowed);
  await stop();await start();
  const done=await request('/admin/runtime/plan/replacement?config='+encodeURIComponent(root));assert.equal(done.allowed,true);assert.equal(done.actions.length,0);
  await until(async()=>{const r=await publicRequest(`http://127.0.0.1:${next}/updated`);return r.status===200 && (await r.text()).includes('common-form-updated');});
  assert.equal(fs.readFileSync(path.join(dir,'main.mjs'),'utf8'),entry);
  assert.equal(fs.readFileSync(root,'utf8'),original);
  for(const f of [listener,routes,app])assert(!fs.readFileSync(f,'utf8').includes('extra-vjsx') && !fs.readFileSync(f,'utf8').includes('extra-out'));

 } catch(error) {failure=Error('Phase '+phase+': '+error.message+'\n'+logs,{cause:error});throw failure;} finally {
  try { await stop(); } catch(cleanup) { throw new AggregateError(failure?[failure,cleanup]:[cleanup],'Common config cleanup failed during '+phase); }
  finally { if(process.env.VHTTPD_E2E_KEEP_TMP==='1') console.error('Retained common config fixture: '+dir);else fs.rmSync(dir,{recursive:true,force:true}); }
 }

});
