import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import net from 'node:net';import https from 'node:https';import {spawn,execFileSync} from 'node:child_process';
const repo=process.cwd();const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function port(){const server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const p=server.address().port;await new Promise(r=>server.close(r));return p;}
async function until(fn,ms=60000){const end=Date.now()+ms;let last;while(Date.now()<end){try{if(await fn())return;}catch(e){last=e;}await pause(100);}throw last || Error('Timed out');}
test('business HTTP metrics aggregate across listeners and preserve route/error/latency identity',{timeout:180000},async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-http-metrics-'));const admin=await port(),web=await port(),second=await port();let child;
 const cert=path.join(dir,'listener.crt'),key=path.join(dir,'listener.key'),certConfig=path.join(dir,'listener.cnf');
 fs.writeFileSync(certConfig,'[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=extensions\n[subject]\nCN=127.0.0.1\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n');
 const token='metrics-fixture-only';const root=path.join(dir,'vhttpd.toml');
 fs.writeFileSync(root,`version=2\ninclude=["listeners.toml","routes.toml","app.toml"]\n[server]\npid_file="${dir}/runtime.pid"\n[observability]\nevent_log="${dir}/events.ndjson"\n[control]\nlistener="listener:admin"\ntoken="${token}"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${admin}\n`);
 fs.writeFileSync(path.join(dir,'listeners.toml'),`[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=${web}\n[listeners.web.tls]\nenabled=true\ncert="${cert}"\ncert_key="${key}"\n[listeners.second]\nprotocol="http"\nhost="127.0.0.1"\nport=${second}\n`);
 fs.writeFileSync(path.join(dir,'main.mjs'),`
import fs from 'node:fs';
const root=${JSON.stringify(dir)};
export default function(ctx){
 const gate=ctx.queryParam('gate','');
 if(gate.startsWith('success-') || gate==='timeout'){
  const file=root+'/'+gate;
  fs.writeFileSync(file+'.entered','ready');
  const guard=Date.now()+10000;
  while(!fs.existsSync(file+'.release')){
   if(Date.now()>guard)throw Error('metrics fixture gate was not released: '+gate);
   const next=Date.now()+5;while(Date.now()<next){} // Bound filesystem polling while the lane is held.
  }
 }
 if(!gate){const end=Date.now()+120;while(Date.now()<end){}}
 return ctx.json({ok:true},200);
}`);
 fs.writeFileSync(path.join(dir,'asset.txt'),'asset contents');
 fs.writeFileSync(path.join(dir,'app.toml'),`[engines.slow]\nkind="vjsx"\nentry="${dir}/main.mjs"\nruntime_profile="node"\nenable_fs=true\nthread_count=1\n[adapters.slow]\nkind="http-handler"\nengine="engine:slow"\n[adapters.ok]\nkind="fixed-response"\noptions.status="200"\noptions.body="ok"\n[adapters.missing]\nkind="fixed-response"\noptions.status="404"\n[adapters.fail]\nkind="fixed-response"\noptions.status="503"\noptions.body="not-ready"\n[adapters.timeout]\nkind="fixed-response"\noptions.status="504"\n[adapters.asset]\nkind="static"\nroot="${dir}"\n`);
 let routes='';for(const [id,listener,url,outlet] of [['ok','web','/ok','ok'],['fail','web','/fail','fail'],['missing','web','/missing','missing'],['timeout','web','/timeout','timeout'],['slow','web','/slow','slow'],['slow-shared','web','/shared-slow','slow'],['asset','web','/asset.txt','asset'],['other','second','/other','ok']])routes+=`[[pipelines]]\nid="${id}"\ningress="listener:${listener}"\nmatch.paths=["${url}"]\nmatch.methods=["GET"]\negress="adapter:${outlet}"\n`;
 fs.writeFileSync(path.join(dir,'routes.toml'),routes);
 const output=fs.openSync(path.join(dir,'runtime.log'),'a');
 const api=async suffix=>{const r=await fetch(`http://127.0.0.1:${admin}/admin/`+suffix,{headers:{'x-vhttpd-admin-token':token,connection:'close'},signal:AbortSignal.timeout(4000)});assert.equal(r.status,200);return r.json();};
 // TLS dispatches accepted connections independently, so contenders reach the executor lane.
 // Trust only this fixture certificate; keep the other business listener and admin on HTTP.
 const requestWeb=url=>new Promise((resolve,reject)=>{
  const request=https.get({hostname:'127.0.0.1',port:web,path:url,ca:fs.readFileSync(cert),agent:false,headers:{connection:'close'},signal:AbortSignal.timeout(10000)},response=>{
   response.resume();response.once('error',reject);response.once('end',()=>resolve({status:response.statusCode,observationId:response.headers['x-vhttpd-observation-id']}));
  });
  request.once('error',reject);
 });
 const req=async(p,url,status)=>{if(p===web){const r=await requestWeb(url);assert.equal(r.status,status);return r.observationId;}const r=await fetch(`http://127.0.0.1:${p}`+url,{headers:{connection:'close'},signal:AbortSignal.timeout(10000)});await r.text();assert.equal(r.status,status);return r.headers.get('x-vhttpd-observation-id');};
 // Hold the executor before opening independently dispatched competing connections.
 const withHeldLane=async(gate,target,run)=>{
  const release=()=>fs.writeFileSync(path.join(dir,gate+'.release'),'release');
  const held=req(web,target+'?gate='+gate,200).then(value=>({value}),error=>({error}));
  try{
   await until(()=>fs.existsSync(path.join(dir,gate+'.entered')),5000);
   await run(release);
  }finally{
   release();
   const result=await held;
   if(result.error)throw result.error;
  }
 };
 try{
  execFileSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',certConfig,'-keyout',key,'-out',cert],{stdio:['ignore','pipe','pipe']});
  child=spawn(process.env.VHTTPD_BIN || path.join(repo,'vhttpd'),['--config',root],{cwd:repo,env:{...process.env,VHTTPD_LOG_LEVEL:'info'},stdio:['ignore',output,output]});
  await until(async()=>{if(child.exitCode!==null)throw Error('Runtime exited');return (await api('runtime')).listeners.filter(l=>l.http_metrics).length===3;});
  await until(async()=>{await req(web,'/ok',200);return true;});
  const baseline=(await api('runtime')).listeners.find(l=>l.listener_id==='web').http_metrics.requests_total;
  for(let i=0;i<10;i++)await api('runtime'); // Polling must not inflate business counts.
  const errorId=await req(web,'/fail?token=must-not-be-recorded',503);
  await req(web,'/timeout',504);await req(web,'/missing?secret=do-not-store',404);await req(web,'/unrouted',200);const slowId=await req(web,'/slow?token=slow-secret-do-not-store',200);await req(web,'/asset.txt',200);
  await Promise.all(Array.from({length:12},()=>req(second,'/other',200)));
  const snapshot=await api('runtime');const one=snapshot.listeners.find(l=>l.listener_id==='web'),two=snapshot.listeners.find(l=>l.listener_id==='second');
  assert.equal(one.is_control,false);assert.equal(snapshot.listeners.find(l=>l.listener_id==='admin').is_control,true);
  assert.equal(one.http_metrics.requests_total,baseline+6);assert.equal(two.http_metrics.requests_total,12);
  assert.equal(one.http_metrics.client_errors_total,1);assert.equal(one.http_metrics.server_errors_total,2);assert.equal(one.http_metrics.timeouts_total,1);
  const slow=one.route_metrics.find(r=>r.pipeline_id==='slow').metrics;
  assert.equal(slow.requests_total,1);assert(slow.duration_sum_ms>=100,JSON.stringify(slow));assert.equal(slow.duration_buckets[8],1);
  assert.equal(one.route_metrics.find(r=>r.pipeline_id==='asset').metrics.requests_total,1);
  assert.equal(one.route_metrics.find(r=>r.pipeline_id==='').metrics.requests_total,1);
  assert(one.recent_errors.some(e=>e.observation_id===errorId && e.pipeline_id==='fail' && e.status===503));
  assert(!JSON.stringify(snapshot.listeners).includes('must-not-be-recorded'));assert(!JSON.stringify(snapshot.listeners).includes('do-not-store'));
  // Recovery changes the latest result without erasing historical errors.
  await req(web,'/ok',200);assert.equal((await api('runtime')).listeners.find(l=>l.listener_id==='web').http_metrics.last_status,200);
  await req(web,'/fail',503);
  const window=await api('http/traffic?window=60');
  const cumulative=(await api('runtime')).listeners.filter(l=>!l.is_control).reduce((sum,l)=>sum+l.http_metrics.requests_total,0);
  assert.equal(window.metrics.requests_total,cumulative);
  assert.equal(window.series.reduce((sum,p)=>sum+p.metrics.requests_total,0),cumulative);
  assert.equal(window.window_seconds,60);assert(window.series.length<=7);assert(window.series.every(p=>p.span_seconds>0));
  const selected=await api('http/traffic?window=300&listener=web&route=1&pipeline=slow');
  assert.equal(selected.metrics.requests_total,1);assert(selected.metrics.duration_max_ms>=100);assert.equal(selected.listeners.length,1);assert.equal(selected.listeners[0].routes[0].pipeline_id,'slow');
  const defaultRoute=await api('http/traffic?window=60&listener=web&route=1&pipeline=');assert.equal(defaultRoute.metrics.requests_total,1);
  const details=await api('http/requests?window=60&listener=web&pipeline=slow&min_ms=100');
  assert.equal(details.requests.length,1);assert.equal(details.requests[0].request.observation_id,slowId);assert(details.requests[0].request.duration_ms>=100);
  const stages=details.requests[0].request.stages;
  assert.equal(stages.available,true);assert.equal(stages.queue_observed,true);assert.equal(stages.vjsx_observed,true);assert.equal(stages.adapter_observed,true);
  assert(stages.vjsx_ms>=100,JSON.stringify(stages));
  const sum=stages.queue_ms+stages.vjsx_ms+stages.adapter_ms+stages.other_ms;assert(Math.abs(sum-details.requests[0].request.duration_ms)<2,JSON.stringify(stages));
  const terminal=one.recent_errors.find(e=>e.pipeline_id==='fail').stages;assert.equal(terminal.adapter_observed,true);assert.equal(terminal.queue_observed,false);assert.equal(terminal.vjsx_observed,false);
  assert.equal(details.requests[0].request.status,200);assert(details.requests[0].log_line.includes(slowId));
  assert(!JSON.stringify(details).includes('slow-secret-do-not-store'));assert(!JSON.stringify(details).includes('token='));
  await until(()=>fs.readFileSync(path.join(dir,'runtime.log'),'utf8').includes(details.requests[0].log_line));
  assert.equal((await api('http/requests?window=60&listener=web&pipeline=slow&min_ms=99999')).requests.length,0);
  const focusUrl=`http://127.0.0.1:${admin}/admin/workbench/log-focus`;
  const focusBody=JSON.stringify({listener:'web',pipeline:'slow',observation_id:slowId});
  const focusPost=()=>fetch(focusUrl,{method:'POST',headers:{'content-type':'application/json','x-vhttpd-admin-token':token},body:focusBody});
  assert.equal((await focusPost()).status,409); // A browser cannot claim a disconnected host.
  assert.equal((await fetch(focusUrl)).status,403);
  assert.equal((await fetch(focusUrl,{headers:{'x-vhttpd-admin-token':token,origin:'http://foreign.example'}})).status,403);
  assert.equal((await api('workbench/log-focus')).serial,0);
  assert.equal((await focusPost()).status,200);
  const focused=await api('workbench/log-focus');assert.equal(focused.observation_id,slowId);assert.equal(focused.serial,1);
  const missingFocus=await fetch(focusUrl,{method:'POST',headers:{'content-type':'application/json','x-vhttpd-admin-token':token},body:JSON.stringify({listener:'second',pipeline:'slow',observation_id:slowId})});assert.equal(missingFocus.status,404);
  const deniedDetails=await fetch(`http://127.0.0.1:${admin}/admin/http/requests?listener=web&pipeline=slow`,{signal:AbortSignal.timeout(3000)});assert.equal(deniedDetails.status,403);
  const noAccess=await fetch(`http://127.0.0.1:${admin}/admin/http/traffic?window=60`,{signal:AbortSignal.timeout(3000)});assert.equal(noAccess.status,403);
  const executorSnapshot=await api('http/executors');
  const selectedExecutor=snapshot=>snapshot.instances.find(item=>item.listener_id==='web' && item.routes.some(route=>route.pipeline_id==='slow'));
  const initialExecutor=selectedExecutor(executorSnapshot);assert(initialExecutor);assert(initialExecutor.routes.some(route=>route.pipeline_id==='slow-shared'));assert(!initialExecutor.routes.some(route=>route.pipeline_id==='asset'));assert(initialExecutor.engine_ids.includes('slow'));
  const sourceFiles=await api('config/files');assert(sourceFiles.find(file=>file.path.endsWith('/app.toml')).engine_ids.includes('slow'));
  assert(!JSON.stringify(executorSnapshot).includes('module_root'));assert(!JSON.stringify(executorSnapshot).includes('metrics-fixture-only'));
  const noExecutorAccess=await fetch(`http://127.0.0.1:${admin}/admin/http/executors`);assert.equal(noExecutorAccess.status,403);
  // Exercise all six successful waits separately: each keeps the production 1s
  // admission budget instead of adding six serial 120ms handlers to one deadline.
  for(let i=0;i<6;i++)await withHeldLane('success-'+i,'/slow',async release=>{
   const pending=req(web,'/slow?token=stage-secret-do-not-store',200).then(value=>({value}),error=>({error}));
   let result;
   try{
    await until(async()=>{const load=selectedExecutor(await api('http/executors')).load;return load.waiting>0 && load.occupied===load.capacity;},5000);
    await pause(100); // Keep a measurable queue interval after observed admission.
   }finally{release();result=await pending;}
   if(result.error)throw result.error;
  });
  const settled=selectedExecutor(await api('http/executors')).load;assert.equal(settled.waiting,0);assert.equal(settled.occupied,0);
  await withHeldLane('timeout','/shared-slow',async release=>{
   const queued=requestWeb('/shared-slow')
    .then(r=>({status:r.status})).catch(error=>({error}));
   try{
    await until(async()=>selectedExecutor(await api('http/executors')).load.queue_timeouts_total>settled.queue_timeouts_total,5000);
    const result=await queued;
    if(result.error)throw result.error;
    assert(result.status>=400,'contending request must report queue timeout');
   }finally{release();await queued;}
  });
  const afterTimeout=selectedExecutor(await api('http/executors')).load;assert.equal(afterTimeout.waiting,0);assert.equal(afterTimeout.occupied,0);assert(afterTimeout.last_queue_timeout_unix>0);

  const queued=await api('http/requests?window=60&listener=web&pipeline=slow&min_ms=100');
  assert(queued.requests.some(item=>item.request.stages.queue_ms>=80),JSON.stringify(queued.requests.map(i=>i.request.stages)));
  assert(queued.requests.filter(item=>item.request.status===200).every(item=>item.request.stages.vjsx_observed && item.request.stages.vjsx_ms>=100));
  const sharedQueued=await api('http/requests?window=60&listener=web&pipeline=slow-shared&min_ms=100');
  assert(sharedQueued.requests.some(item=>item.request.status>=400 && item.request.stages.queue_observed && !item.request.stages.vjsx_observed));
  assert(!JSON.stringify(queued).includes('stage-secret-do-not-store'));
  console.log('Load checkpoints:',JSON.stringify({capacity:settled.capacity,waiting_after:afterTimeout.waiting,occupied_after:afterTimeout.occupied,queue_waits_total:afterTimeout.queue_waits_total,queue_timeouts_total:afterTimeout.queue_timeouts_total}));
  console.log('Verified per-listener totals, concurrent requests, 404/503/504, static adapter, slow vjsx, control exclusion and safe error samples');

 }catch(error){fs.copyFileSync(path.join(dir,'runtime.log'),path.join(os.tmpdir(),'vhttpd-business-metrics-failure.log'));console.error('Metrics runtime tail:',fs.readFileSync(path.join(dir,'runtime.log'),'utf8').split('\n').slice(-60).join('\n'));throw error;}finally{
  if(child && child.exitCode===null && child.signalCode===null){const done=new Promise(r=>child.once('exit',r));child.kill('SIGTERM');const force=setTimeout(()=>child.kill('SIGKILL'),15000);await done;clearTimeout(force);}
  fs.closeSync(output);fs.rmSync(dir,{recursive:true,force:true});
 }
});
