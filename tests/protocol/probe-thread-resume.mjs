// Explicit live check: creates its own persistent test thread, closes/unloads it,
// then exercises the application's recovery router on a fresh connection.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawn} from 'node:child_process';
import net from 'node:net';
import {recoveryHarness} from '../../examples/codexbot-app-ts/tests/helpers/thread-recovery-harness.mjs';
import {buildThreadResumeParams} from '../../examples/codexbot-app-ts/lib/codex-start-params.mjs';
const args=process.argv.slice(2);
const arg=(name)=>args[args.indexOf(name)+1];
if(!args.includes('--config'))throw Error('Use --config /path/to/bot.local.json [--out /path/to/report.json]');
const configPath=path.resolve(arg('--config'));
let config;
try{config=JSON.parse(fs.readFileSync(configPath,'utf8'));}catch{throw Error('invalid_application_configuration');}
const cfg={...config.codex,...config.codex?.instances?.[config.codex?.default_instance||'main']};
const cwd=path.resolve(path.dirname(configPath),cfg.cwd);
const pause=(ms)=>new Promise(r=>setTimeout(r,ms));
let server;
if(args.includes('--isolated-server')){
  const listener=net.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));
  const port=listener.address().port;await new Promise(r=>listener.close(r));
  cfg.url=`ws://127.0.0.1:${port}`;
}
async function startServer(){
  if(!args.includes('--isolated-server'))return;
  server=spawn(args.includes('--codex')?arg('--codex'):'codex',['app-server','--listen',cfg.url],{stdio:'ignore'});
  server.on('error',()=>{});
  for(let attempt=0;attempt<100;attempt++){
    const ready=await new Promise(resolve=>{const socket=net.connect(Number(new URL(cfg.url).port),'127.0.0.1');socket.on('connect',()=>{socket.destroy();resolve(true)});socket.on('error',()=>resolve(false));});
    if(ready)return;
    if(server.exitCode!==null)throw Error('isolated_server_exited');
    await pause(100);
  }
  throw Error('isolated_server_timeout');
}
async function stopServer(){
  if(!server)return;
  const child=server;server=null;
  await new Promise(resolve=>{child.once('exit',resolve);child.kill('SIGTERM');});
}
class Client {
  constructor(url){
    this.ws=new WebSocket(url);this.sequence=0;this.pending=new Map();this.turn=null;this.calls=[];
    this.ready=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('connect_timeout')),10000);this.ws.onopen=()=>{clearTimeout(timer);resolve();};this.ws.onerror=()=>{clearTimeout(timer);reject(Error('connect_failed'));};});
    this.ws.onmessage=(event)=>{
      const message=JSON.parse(String(event.data));const waiter=this.pending.get(message.id);
      if(waiter){this.pending.delete(message.id);message.error?waiter.reject(Error(`rpc_${message.error.code}`)):waiter.resolve(message.result);return;}
      if(!this.turn||message.params?.threadId!==this.turn.threadId)return;
      if(message.method==='item/completed'&&message.params.item?.type==='agentMessage')this.turn.text=message.params.item.text||this.turn.text;
      if(message.method==='turn/completed')this.turn.resolve({status:message.params.turn?.status,text:this.turn.text});
    };
  }
  async initialize(){await this.ready;await this.rpc('initialize',{clientInfo:{name:'codexbot_thread_resume_probe',version:'1'},capabilities:{}});this.ws.send(JSON.stringify({method:'initialized',params:{}}));}
  rpc(method,params={}){
    this.calls.push(method);
    return new Promise((resolve,reject)=>{const id=++this.sequence;const timer=setTimeout(()=>{this.pending.delete(id);reject(Error('rpc_timeout'));},30000);this.pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v)},reject:e=>{clearTimeout(timer);reject(e)}});this.ws.send(JSON.stringify({id,method,params}));});
  }
  async runTurn(params){
    let timer;
    const completed=new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('turn_timeout')),60000);this.turn={threadId:params.threadId,text:'',resolve};});
    completed.catch(()=>{});
    try{await this.rpc('turn/start',params);return await completed;}finally{clearTimeout(timer);this.turn=null;}
  }
  async close(){for(const p of this.pending.values())p.reject(Error('closed'));this.pending.clear();this.ws.close();await pause(100);}
}
let first,second,threadId;
const report={ok:false};
try{
  await startServer();
  first=new Client(cfg.url);await first.initialize();
  const created=await first.rpc('thread/start',{model:cfg.model,cwd,approvalPolicy:'never',sandbox:'read-only'});threadId=created.thread.id;
  const marker='RESUME_PROBE_'+randomUUID().replaceAll('-','');
  const saved=await first.runTurn({threadId,input:[{type:'text',text:`Remember the exact marker ${marker} for the next turn. Reply only SAVED. Do not use tools.`}],effort:'low'});
  assert.equal(saved.status,'completed');
  await first.rpc('thread/unsubscribe',{threadId});await first.close();first=null;
  if(args.includes('--isolated-server')){await stopServer();await startServer();}
  second=new Client(cfg.url);await second.initialize();
  let before;
  for(let attempt=0;attempt<10;attempt++){
    before=await second.rpc('thread/read',{threadId,includeTurns:false});
    if(before.thread.status?.type==='notLoaded')break;
    await pause(200);
  }
  assert.equal(before.thread.status?.type,'notLoaded','fixture must be unloaded before recovery');
  const h=recoveryHarness(threadId);Object.assign(h.defaults,{model:cfg.model,cwd});Object.assign(h.chat,{model:cfg.model,cwd});
  h.stream.prompt='What exact marker did I ask you to remember in the previous turn? Reply with only that marker. Do not use tools.';
  const resumed=await second.rpc('thread/resume',buildThreadResumeParams(h.chat,h.defaults));
  const response=await h.respond('thread/resume',resumed);
  assert.equal(response.commands.length,1);assert.equal(response.commands[0].method,'turn/start');assert.equal(response.commands[0].params.threadId,threadId);
  const continued=await second.runTurn(response.commands[0].params);
  assert.equal(continued.status,'completed');assert.equal(continued.text.trim(),marker);
  assert.equal(h.calls.resets,0);assert.ok(!second.calls.includes('thread/start'));
  await second.rpc('thread/archive',{threadId});
  Object.assign(report,{ok:true,testThreadId:threadId,beforeResume:'notLoaded',sameThreadId:true,historyPreserved:true,newThreadCreatedOnReconnect:false,fixtureArchived:true});
}catch(error){
  report.failure=error.code||error.message;report.testThreadId=threadId;
  throw error;
}finally{
  if(first)await first.close();if(second)await second.close();
  await stopServer();
  if(args.includes('--out'))fs.writeFileSync(path.resolve(arg('--out')),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report));
}
