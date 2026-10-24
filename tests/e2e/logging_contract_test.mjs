import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
const repo=process.cwd();
const binary=process.env.VHTTPD_BIN || path.join(repo,'vhttpd');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
async function until(fn){let last;const end=Date.now()+60000;while(Date.now()<end){try{if(await fn())return;}catch(e){last=e;}await pause(50);}throw last || Error('logging contract timed out');}
for(const format of ['text','json']) test(`production logging preserves event identity and ${format} console contract`,{timeout:90000},async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-log-contract-'));const web=await port();const events=path.join(root,'events.ndjson');const config=path.join(root,'runtime.toml');
 fs.writeFileSync(config,`version=2\n[server]\npid_file="${root}/runtime.pid"\n[observability]\nevent_log="${events}"\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=${web}\n[adapters.reply]\nkind="fixed-response"\noptions.status="200"\noptions.body="ok"\n[[pipelines]]\nid="probe"\ningress="listener:web"\nmatch.paths=["/probe"]\nmatch.methods=["GET"]\negress="adapter:reply"\n`);
 let output='',stdout='',stderr='';const child=spawn(binary,['--config',config,'--feishu-enabled','false'],{cwd:repo,env:{...process.env,VHTTPD_LOG_LEVEL:'info',VHTTPD_LOG_FORMAT:format}});
 child.stdout.on('data',b=>{stdout+=b;output+=b;});child.stderr.on('data',b=>{stderr+=b;output+=b;});
 const done=new Promise(r=>child.once('close',r));const rows=()=>fs.existsSync(events)?fs.readFileSync(events,'utf8').trim().split('\n').filter(Boolean).map(x=>JSON.parse(x)):[];
 try {
  await until(async()=>{assert.equal(child.exitCode,null,output);return (await fetch(`http://127.0.0.1:${web}/health`,{signal:AbortSignal.timeout(1000)})).ok;});
  const trace=`logging-${format}`;const response=await fetch(`http://127.0.0.1:${web}/probe?trace_id=${trace}`,{headers:{'x-request-id':`request-${format}`,connection:'close'}});assert.equal(response.status,200);assert.equal(await response.text(),'ok');
  await until(()=>rows().some(r=>r.type==='http.request' && r.trace_id===trace));
  assert.equal(rows().filter(r=>r.type==='server.started').length,1);
  const matching=rows().filter(r=>r.type==='http.request' && r.trace_id===trace);assert.equal(matching.length,1);assert.equal(matching[0].request_id,`request-${format}`);assert.equal(matching[0].status,'200');assert.ok(Number(matching[0].ts)>0);
  await until(()=>output.includes('vhttpd timezone:'));
  if(format==='json'){
   const consoleRows=stderr.trim().split('\n').filter(Boolean).map(x=>JSON.parse(x));assert.ok(consoleRows.length>0);
   for(const row of consoleRows){assert.equal(row.type,'runtime.log');assert.ok(['debug','info','warn','error','fatal'].includes(row.level));assert.ok(Number(row.ts)>0);assert.equal(row.pid,String(child.pid));assert.equal(typeof row.message,'string');}
   assert.ok(consoleRows.some(r=>r.message.includes('vhttpd timezone:')));
  }else assert.match(stderr,/\[.*INFO.*\]/);
  await until(()=>stdout.includes('[veb] Running multi-threaded app on http://') && stdout.includes('listening on http://'));
  assert.match(stdout,/\[veb\] Running multi-threaded app on http:\/\//);
  assert.match(stdout,/listening on http:\/\//);
 } finally {
  if(child.exitCode===null){child.kill('SIGTERM');const exited=await Promise.race([done.then(()=>true),pause(5000).then(()=>false)]);if(!exited){child.kill('SIGKILL');await done;}}
  fs.writeFileSync(path.join(root,'console.log'),output);fs.writeFileSync(path.join(root,'stdout.log'),stdout);fs.writeFileSync(path.join(root,'stderr.log'),stderr);
  if(process.env.VHTTPD_E2E_KEEP_TMP!=='1')fs.rmSync(root,{recursive:true,force:true});
 }
});

test('JSON console includes configuration failures before timezone initialization',{timeout:30000},async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-log-startup-'));let output='';
 const child=spawn(binary,['--config',path.join(root,'missing.toml')],{cwd:repo,env:{...process.env,VHTTPD_LOG_FORMAT:'json'}});
 child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
 try {
  const code=await new Promise(r=>child.once('close',r));assert.notEqual(code,0);
  const rows=output.trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
  assert.ok(rows.some(r=>r.type==='runtime.log' && r.level==='error' && r.message.includes('config load failed')));
 } finally {if(child.exitCode===null)child.kill('SIGKILL');fs.rmSync(root,{recursive:true,force:true});}
});
