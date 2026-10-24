import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import {fileURLToPath} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const binary=process.env.VHTTPD_BIN || path.join(repo,'vhttpd');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn){const deadline=Date.now()+60000;while(Date.now()<deadline){if(await fn())return;await pause(50);}throw new Error('condition timed out');}
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
test('real PHP and TS one-shot reply producers spend trusted credentials and cannot replay revoked contexts',{timeout:120000},async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-one-shot-')),token=randomBytes(32).toString('hex');
 let child,done,ws,output='',posts=0,adminOrigin='',sendMode='success',issueResponseMode='success';const issuance=[],revocations=[];
 const api=http.createServer((req,res)=>{
  req.resume();res.setHeader('Content-Type','application/json');
  if(req.url.includes('tenant_access_token')) return res.end(JSON.stringify({code:0,tenant_access_token:'fixture',expire:7200}));
  if(req.method==='POST' && req.url.includes('/im/v1/messages')) {
   posts++; const mode=sendMode;sendMode='success';
   if(mode==='disconnect') return req.socket.destroy();
   if(mode==='reject') return res.end(JSON.stringify({code:999,msg:'fixture send failure'}));
   return res.end(JSON.stringify({code:0,data:{message_id:'physical-'+posts}}));
  }
  res.end(JSON.stringify({code:1,msg:'no websocket fixture'}));
 });
 const proxy=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',async()=>{try{if(req.method==='POST' && req.url==='/admin/runtime/feishu/creation')issuance.push(JSON.parse(body));if(req.method==='POST' && req.url.endsWith('/revoke'))revocations.push(JSON.parse(body));const response=await fetch(adminOrigin+req.url,{method:req.method,headers:{'x-vhttpd-admin-token':req.headers['x-vhttpd-admin-token'] || '', 'Content-Type':'application/json'},body:req.method==='GET'?undefined:body});res.writeHead(response.status,{'Content-Type':'application/json'});const text=await response.text();if(req.url==='/admin/runtime/feishu/creation' && req.method==='POST' && issueResponseMode==='malformed'){issueResponseMode='success';res.end('malformed-response');}else res.end(text);}catch(error){res.writeHead(500);res.end(String(error));}});});
 async function php({failure=false}={}){const p=spawn('php',['-d','display_errors=stderr','tests/protocol/feishu-one-shot-reply.php'],{cwd:repo,env:{...process.env,VHTTPD_ADMIN_BASE_URL:`http://127.0.0.1:${proxy.address().port}`,VHTTPD_ADMIN_TOKEN:token}});let out='',err='';p.stdout.on('data',b=>out+=b);p.stderr.on('data',b=>err+=b);p.stdin.end(JSON.stringify({action:'produce'}));const code=await new Promise(r=>p.once('close',r));if(failure){assert.notEqual(code,0);assert.equal(out,'');return err;}assert.equal(code,0,err);return JSON.parse(out);}
 try{
  await new Promise(r=>api.listen(0,'127.0.0.1',r));await new Promise(r=>proxy.listen(0,'127.0.0.1',r));
  const web=await port();let admin;do{admin=await port();}while(admin===web);adminOrigin=`http://127.0.0.1:${admin}`;
  const entry=path.join(root,'reply-app.mts');
  fs.writeFileSync(entry,`import {createReplyContext} from ${JSON.stringify(path.join(repo,'examples/codexbot-app-ts/lib/state.mjs'))};
import {createFeishuSessionHelpers,completeReplyResponse} from ${JSON.stringify(path.join(repo,'examples/codexbot-app-ts/lib/feishu-session-helpers.mjs'))};
import {feishuText} from ${JSON.stringify(path.join(repo,'examples/codexbot-app-ts/lib/commands.mts'))};
const helpers=createFeishuSessionHelpers({createReplyContext,feishuText,helpText:()=>"TS one-shot"});
export async function http(ctx){return ctx.path==="/produce"?ctx.json(completeReplyResponse(helpers.handleHelp({chatId:"chat",instance:"main"}))):ctx.json({ok:true});}
export default {http};
`);
  const config=path.join(root,'hub.toml');fs.writeFileSync(config,`[server]\nhost="127.0.0.1"\nport=${web}\n[files]\npid_file="${root}/hub.pid"\nevent_log="${root}/events.ndjson"\n[executor]\nkind="vjsx"\n[vjsx]\napp_entry="${entry}"\nruntime_profile="node"\nthread_count=1\nenable_fs=true\n[admin]\nenabled=true\nhost="127.0.0.1"\nport=${admin}\ntoken="${token}"\non_data_plane=false\n[bridge]\nenabled=false\ntoken="${token}"\n`);
  child=spawn(binary,['--config',config,'--port',String(web),'--admin-port',String(admin),'--feishu-enabled','true','--feishu-app-id','fixture','--feishu-app-secret','fixture','--feishu-open-base-url',`http://127.0.0.1:${api.address().port}/open-apis`],{cwd:repo,env:{...process.env,CODEXBOT_TS_DB_PATH:path.join(root,'ts.sqlite')}});child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);done=new Promise(r=>child.once('close',r));
  await until(async()=>{assert.equal(child.exitCode,null,output);try{return(await fetch(adminOrigin+'/health')).ok && (await fetch(`http://127.0.0.1:${web}/health`)).ok;}catch{return false;}});
  ws=new WebSocket(`ws://127.0.0.1:${web}/bridge/ws?client_id=one-shot&token=${token}`);const pending=new Map();ws.addEventListener('message',event=>{const result=JSON.parse(String(event.data));const cb=pending.get(result.request_id);if(cb){pending.delete(result.request_id);cb(result);}});await new Promise((r,j)=>{ws.addEventListener('open',r,{once:true});ws.addEventListener('error',j,{once:true});});
  const call=(action,command)=>new Promise((resolve,reject)=>{const id=randomBytes(12).toString('hex'),timer=setTimeout(()=>{pending.delete(id);reject(new Error('bridge timeout '+action));},8000);pending.set(id,result=>{clearTimeout(timer);resolve(result);});ws.send(JSON.stringify({type:'feishu_proxy_request',request_id:id,action,request:{...command,metadata:{...command.metadata,stream_id:command.stream_id}}}));});
  const ts=async()=>{const res=await fetch(`http://127.0.0.1:${web}/produce`);const text=await res.text();assert.equal(res.status,200,text);return JSON.parse(text);};
  for(const produce of [php,ts]){
   const first=await produce(),second=await produce();const [send,clear]=first.commands;const [other,otherClear]=second.commands;
   assert.equal(first.commands.length,2);assert.equal(send.type,'provider.message.send');assert.equal(clear.type,'session.clear');assert.ok(send.stream_id.startsWith('feishu:reply:'));assert.notEqual(send.stream_id,other.stream_id);assert.equal(clear.stream_id,send.stream_id);assert.equal(clear.metadata.stream_generation,send.metadata.stream_generation);assert.ok(!JSON.stringify(first).includes(token));
   const saved=JSON.stringify(send),count=posts;const result=await call('send',send);assert.equal(result.ok,true,JSON.stringify(result));assert.equal(posts,count+1);assert.equal((await call('clear',clear)).ok,true);
   const issues=issuance.length;
   assert.equal((await call('send',JSON.parse(saved))).ok,false);assert.equal((await call('send',{...send,stream_id:'',metadata:{}})).ok,false);assert.equal(posts,count+1);assert.equal(issuance.length,issues);
   assert.equal((await call('send',other)).ok,true,'old cleanup revoked unrelated reply');assert.equal((await call('clear',otherClear)).ok,true);
  }
  // Deliberately omit cleanup after successful send, or fail it with an invalid
  // physical target. Reply completion itself must leave no stream to operate on.
  for(const produce of [php,ts]){
   for(const mode of ['success','reject','disconnect']){
    const reply=await produce(),[command,clear]=reply.commands;
    const count=posts;sendMode=mode;
    const result=await call('send',command);
    assert.equal(result.ok,mode==='success',JSON.stringify(result));
    assert.equal(posts,count+1);
    if(mode==='success'){
     assert.equal((await call('append',{...command,target:result.message_id,target_type:'message_id',text:'late append'})).ok,false,'completed reply retained a streaming buffer');
    }
    assert.equal((await call('clear',{...clear,target:'missing-physical',target_type:'message_id'})).ok,true);
    assert.equal((await call('send',JSON.parse(JSON.stringify(command)))).ok,false,'failed/uncleared reply was replayable');
    assert.equal(posts,count+1);
   }
  }
  const beforeLost=issuance.length,beforeRevoke=revocations.length,beforePosts=posts;
  issueResponseMode='malformed';
  const issueFailure=await php({failure:true});assert.match(issueFailure,/JSON|Syntax/i);
  assert.equal(issuance.length,beforeLost+1,'failed response triggered new issuance');
  assert.equal(revocations.length,beforeRevoke+1);
  assert.deepEqual(revocations.at(-1),issuance.at(-1));
  const replayIssue=await fetch(adminOrigin+'/admin/runtime/feishu/creation',{method:'POST',headers:{'Content-Type':'application/json','x-vhttpd-admin-token':token},body:JSON.stringify(issuance.at(-1))});
  assert.equal(replayIssue.status,409,'revoked issue intent became live again');assert.equal(posts,beforePosts);
  const cancelled=await php();const command=cancelled.commands[0];const request=issuance.find(x=>x.stream_id===command.stream_id);assert.ok(request);
  const revoked=await fetch(adminOrigin+'/admin/runtime/feishu/creation/revoke',{method:'POST',headers:{'Content-Type':'application/json','x-vhttpd-admin-token':token},body:JSON.stringify(request)});assert.equal(revoked.status,200);
  const count=posts,issues=issuance.length;assert.equal((await call('send',command)).ok,false);assert.equal(posts,count);assert.equal(issuance.length,issues);assert.equal(child.exitCode,null,output);
 }catch(error){console.error(output.slice(-12000));console.error('fixture config',fs.readFileSync(path.join(root,'hub.toml'),'utf8').replaceAll(token,'[test token]'));throw error;}
 finally{ws?.close();if(child && child.exitCode===null){child.kill('SIGTERM');const timer=setTimeout(()=>child.kill('SIGKILL'),7000);await done;clearTimeout(timer);}await new Promise(r=>proxy.close(r));await new Promise(r=>api.close(r));fs.rmSync(root,{recursive:true,force:true});}
});
