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
async function port(){const s=net.createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
async function until(fn,ms=15000){const end=Date.now()+ms;let last;while(Date.now()<end){try{const x=await fn();if(x)return x;}catch(e){last=e;}await pause(50);}throw new Error('condition timed out: '+(last?.message || 'not ready'));}
function frame(value){const data=Buffer.from(JSON.stringify(value));let head;if(data.length<126)head=Buffer.from([0x81,data.length]);else{head=Buffer.alloc(4);head[0]=0x81;head[1]=126;head.writeUInt16BE(data.length,2);}return Buffer.concat([head,data]);}
function relayFrames(target,onFrame){let bytes=Buffer.alloc(0),upgraded=false;return data=>{
 bytes=Buffer.concat([bytes,data]);
 if(!upgraded){const end=bytes.indexOf('\r\n\r\n');if(end<0)return;target.write(bytes.subarray(0,end+4));bytes=bytes.subarray(end+4);upgraded=true;}
 while(bytes.length>=2){let size=bytes[1]&127,offset=2;if(size===126){if(bytes.length<4)return;size=bytes.readUInt16BE(2);offset=4;}else if(size===127){if(bytes.length<10)return;size=Number(bytes.readBigUInt64BE(2));offset=10;}const masked=!!(bytes[1]&128),start=offset+(masked?4:0);if(bytes.length<start+size)return;const raw=bytes.subarray(0,start+size),payload=Buffer.from(bytes.subarray(start,start+size));if(masked)for(let i=0;i<payload.length;i++)payload[i]^=bytes[offset+i%4];bytes=bytes.subarray(start+size);let value;try{if((raw[0]&15)===1)value=JSON.parse(payload.toString());}catch{}if(onFrame(value,raw)!==false)target.write(raw);}
};}

test('callback backpressure remains readable, disconnect drains queued work, and stop cancels active RPC',{timeout:120000},async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-bridge-queue-')),token=randomBytes(32).toString('hex');
 const children=[],tunnels=new Set(),requests=new Map(),observed=[],callbacks=new Map();
 let proxy,active,connections=0,hold=false,held,posts=0;
 const api=http.createServer((req,res)=>{req.resume();res.setHeader('Content-Type','application/json');if(req.url.includes('tenant_access_token'))return res.end(JSON.stringify({code:0,tenant_access_token:'fixture',expire:7200}));if(req.url.includes('/im/v1/messages')){if(req.method==='POST')posts++;return res.end(JSON.stringify({code:0,data:{message_id:'same-physical'}}));}res.end(JSON.stringify({code:1,msg:'no provider websocket'}));});
 async function start(name,extra='',native=false){const web=await port();let admin;do{admin=await port();}while(admin===web);const config=path.join(root,name+'.toml');fs.writeFileSync(config,`[server]\nhost="127.0.0.1"\nport=${web}\n[files]\npid_file="${root}/${name}.pid"\nevent_log="${root}/${name}.ndjson"\n[worker]\nautostart=false\n[admin]\nenabled=true\nhost="127.0.0.1"\nport=${admin}\ntoken="${token}"\non_data_plane=false\n${extra}`);const args=['--config',config,'--feishu-enabled','true'];if(native)args.push('--feishu-enabled','true','--feishu-app-id','fixture','--feishu-app-secret','fixture','--feishu-open-base-url',`http://127.0.0.1:${api.address().port}/open-apis`);const child=spawn(binary,args,{cwd:repo});let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);const done=new Promise(r=>child.once('close',r));children.push({child,done,output:()=>output});await until(async()=>{assert.equal(child.exitCode,null,output);return(await fetch(`http://127.0.0.1:${admin}/health`)).ok && (await fetch(`http://127.0.0.1:${web}/health`)).ok;},60000);return {web,admin};}
 const command=(lease,type,target='',text='')=>({type,provider:'feishu',instance:'main',stream_id:lease.scope,target,target_type:target?'message_id':'',text,metadata:{stream_generation:lease.generation,creation_token:lease.token}});
 function submit(commands){assert.ok(active && !active.destroyed,'bridge disconnected');const id=randomBytes(12).toString('hex');active.write(frame({type:'feishu_card_callback',request_id:id,app:'main',event_type:'fixture.commands',target:'chat',target_type:'chat_id',payload:JSON.stringify({commands}),metadata:{event_kind:'event'}}));return id;}
 async function dispatch(commands){const id=submit(commands);return until(()=>callbacks.get(id),8000);}

 try{
  await new Promise(r=>api.listen(0,'127.0.0.1',r));
  const owner=await start('owner',`[bridge]\nenabled=false\ntoken="${token}"\n`,true);
  proxy=net.createServer(down=>{connections++;const connection=connections;active=down;const up=net.connect(owner.web,'127.0.0.1');tunnels.add(down);tunnels.add(up);
   down.on('data',relayFrames(up,(value)=>{if(value?.type==='feishu_card_callback_result'){callbacks.set(value.request_id,{...value,connection});}if(value?.type==='feishu_proxy_request'){requests.set(value.request_id,value);}}));
   up.on('data',relayFrames(down,(value,raw)=>{if(value?.type==='feishu_proxy_result'){const request=requests.get(value.request_id);observed.push({request,result:value});if(hold && request?.action==='append'){hold=false;held={raw:Buffer.from(raw),request,result:value};return false;}}}));
   down.on('error',()=>up.destroy());up.on('error',()=>down.destroy());down.on('close',()=>{tunnels.delete(down);up.destroy();});up.on('close',()=>{tunnels.delete(up);down.destroy();});
  });await new Promise(r=>proxy.listen(0,'127.0.0.1',r));
  const entry=path.join(root,'bot.mts');fs.writeFileSync(entry,`export function http(ctx){if(ctx.path!=="/issue")return ctx.json({ok:true});try{const scope="queue:"+Date.now()+":"+Math.random();const lease=JSON.parse(globalThis.vhttpdHost.issueFeishuStream(scope,"main"));return ctx.json({scope,...lease});}catch(e){return ctx.json({error:String(e)},409);}}\nexport function websocket_upstream(frame){return {handled:true,commands:frame.payloadJson({}).commands || []};}\nexport default {http,websocket_upstream};`);
  const bot=await start('bot',`[executor]\nkind="vjsx"\n[vjsx]\napp_entry="${entry}"\nruntime_profile="node"\nthread_count=1\n[bridge]\nenabled=true\nws_url="ws://127.0.0.1:${proxy.address().port}/bridge/ws"\nclient_id="queue-bot"\ntoken="${token}"\n`);
  const issue=async()=>{const res=await fetch(`http://127.0.0.1:${bot.web}/issue`,{signal:AbortSignal.timeout(10000)});return {status:res.status,body:await res.json()};};
  const first=(await until(async()=>{const r=await issue();return r.status===200?r:null;})).body;
  await dispatch([{...command(first,'provider.message.send','chat','active'),target_type:'chat_id'}]);
  assert.ok(observed.some(x=>x.request?.action==='send' && x.result.ok));
  const firstConnection=connections;
  hold=true;const blocked=submit([command(first,'stream.append','same-physical','blocked')]);await until(()=>held);
  const pending=Array.from({length:16},()=>submit([command(first,'stream.append','same-physical','queued')]));
  const rejected=Array.from({length:4},()=>submit([command(first,'stream.append','same-physical','overflow')]));
  await until(()=>rejected.every(id=>callbacks.get(id)?.status===503));
  for(const id of rejected)assert.equal(callbacks.get(id).error,'bridge_dispatch_capacity');
  assert.equal(connections,firstConnection,'bounded rejection disconnected the active binding');
  assert.equal(callbacks.has(blocked),false);
  active.write(held.raw);held=undefined;
  await until(()=>[blocked,...pending].every(id=>callbacks.get(id)?.status===200));
  for(const id of [blocked,...pending,...rejected])assert.equal(callbacks.get(id).connection,firstConnection);
  const appendCount=observed.filter(x=>x.request?.action==='append').length;
  assert.equal(appendCount,17,'rejected callbacks executed commands');

  // A waiting RPC plus a full callback queue belongs to the old session.
  hold=true;submit([command(first,'stream.append','same-physical','disconnect')]);await until(()=>held);
  const saved=held;held=undefined;
  const discarded=Array.from({length:16},()=>submit([command(first,'session.clear','same-physical')]));
  for(const socket of [...tunnels])socket.destroy();
  await until(()=>connections>firstConnection);
  const fresh=(await until(async()=>{const r=await issue();return r.status===200?r:null;})).body;
  active.write(saved.raw);
  await dispatch([{...command(fresh,'provider.message.send','chat','fresh'),target_type:'chat_id'}]);
  const before=observed.length;
  await dispatch([command(first,'session.clear','same-physical'),command(fresh,'stream.append','same-physical','fresh stays')]);
  assert.ok(observed.slice(before).some(x=>x.request?.action==='append' && x.result.ok),'old cleanup erased replacement binding');
  assert.ok(discarded.every(id=>!callbacks.has(id)),'old queued callback replied through the replacement');
  assert.equal(posts,2,'queued old work caused another provider send');

  // Stop while one callback awaits a proxy result and sixteen remain queued.
  hold=true;submit([command(fresh,'stream.append','same-physical','stop')]);await until(()=>held);
  for(let i=0;i<16;i++)submit([command(fresh,'session.clear','same-physical')]);
  const botProcess=children.at(-1);botProcess.child.kill('SIGTERM');
  let timer;
  try{await Promise.race([botProcess.done,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('session exit blocked behind an active RPC or queued callback')),4500);})]);}finally{clearTimeout(timer);}

 }catch(error){throw new Error(String(error?.stack || error)+'\n'+children.map(x=>x.output().replaceAll(token,'[test token]')).join('\n'));}
 finally{for(const {child,done} of children.reverse()){if(child.exitCode===null)child.kill('SIGTERM');const timer=setTimeout(()=>child.kill('SIGKILL'),7000);await done;clearTimeout(timer);}for(const socket of tunnels)socket.destroy();if(proxy)await new Promise(r=>proxy.close(r));api.closeAllConnections();await new Promise(r=>api.close(r));fs.rmSync(root,{recursive:true,force:true});}
});
