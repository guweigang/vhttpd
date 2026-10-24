import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo, 'vhttpd');
const pause = ms => new Promise(r => setTimeout(r, ms));
async function port() {
  const server = net.createServer();
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const value = server.address().port;
  await new Promise(r => server.close(r));
  return value;
}
async function until(fn, duration = 10000) {
  const deadline = Date.now() + duration;
  let last;
  while (Date.now() < deadline) {
    try { const value = await fn(); if (value) return value; } catch (e) { last = e; }
    await pause(50);
  }
  throw new Error('condition timed out: ' + (last?.message || 'not ready'));
}
async function connect(url) {
  const ws = new WebSocket(url);
  const pending = new Map();
  ws.addEventListener('message', event => {
    const result = JSON.parse(String(event.data));
    const callback = pending.get(result.request_id);
    if (callback) { pending.delete(result.request_id); callback(result); }
  });
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, {once: true}); ws.addEventListener('error', reject, {once: true}); });
  return {
    ws,
    call(action, request, requestId = randomBytes(12).toString('hex'), timeout = 4000) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(requestId); reject(new Error('bridge reply timeout: ' + action)); }, timeout);
        pending.set(requestId, result => { clearTimeout(timer); resolve(result); });
        ws.send(JSON.stringify({type: 'feishu_proxy_request', request_id: requestId, action, request}));
      });
    },
  };
}

test('plain bridge updates fence stale admission and HTTP completion across rebind/revoke/reconnect', {timeout: 60000}, async () => {
 const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vhttpd-update-'));
 const token = randomBytes(32).toString('hex');
 const sockets = [], patches = [];
 let child, done, output = '', release, hold = false, sends = 0, holdSend = false, releaseSend, emptySend = false;
 const api = http.createServer((req, res) => {
  let body = ''; req.on('data', b => { body += b; }); req.on('end', () => {
   const reply = value => { if (res.destroyed || res.writableEnded) return; res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(value)); };
   if (req.url.includes('tenant_access_token')) return reply({code:0, tenant_access_token:'fixture', expire:7200});
   if (req.method === 'PATCH') {
    patches.push(body);
    if (hold) { hold = false; release = () => reply({code:0}); return; }
    return reply({code:0});
   }
   if (req.url.includes('/im/v1/messages') && emptySend) { emptySend=false; sends++; return reply({code:0,data:{message_id:''}}); }
   if (req.url.includes('/im/v1/messages') && holdSend) { holdSend = false; releaseSend = id => reply({code:0,data:{message_id:id}}); return; }
   if (req.url.includes('/im/v1/messages')) return reply({code:0,data:{message_id:'physical-' + (++sends)}});
   reply({code:1,msg:'no provider websocket fixture'});
  });
 });
 try {
  await new Promise(r => api.listen(0, '127.0.0.1', r));
  const web = await port(); let admin; do { admin = await port(); } while (admin === web);
  const config = path.join(root,'hub.toml');
  fs.writeFileSync(config, `[server]\nhost="127.0.0.1"\nport=${web}\n[files]\npid_file="${root}/hub.pid"\nevent_log="${root}/events.ndjson"\n[worker]\nautostart=false\n[admin]\nenabled=true\nhost="127.0.0.1"\nport=${admin}\ntoken="${token}"\non_data_plane=false\n[bridge]\nenabled=false\ntoken="${token}"\n`);
  child = spawn(binary, ['--config',config,'--feishu-enabled','true','--feishu-app-id','fixture','--feishu-app-secret','fixture','--feishu-open-base-url',`http://127.0.0.1:${api.address().port}/open-apis`], {cwd:repo});
  child.stdout.on('data',b=>{output+=b;}); child.stderr.on('data',b=>{output+=b;}); done = new Promise(r=>child.once('close',r));
  await until(async()=>{assert.equal(child.exitCode,null,output);try{return (await fetch(`http://127.0.0.1:${admin}/health`)).ok && (await fetch(`http://127.0.0.1:${web}/health`)).ok;}catch{return false;}});
  const peer = async id => {const p=await connect(`ws://127.0.0.1:${web}/bridge/ws?client_id=${id}&token=${token}`);sockets.push(p.ws);return p;};
  const req = (generation='',target='',text='content',metadata={}) => ({provider:'feishu',instance:'main',target,target_type:target?'message_id':'',text,message_type:'interactive',content:JSON.stringify({elements:[{tag:'markdown',content:text}]}),metadata:{stream_id:'wire',stream_generation:generation,...metadata}});
  let owner = await peer('owner');
  for (const metadata of [{},{stream_id:''},{stream_id:' '}]) {
   assert.equal((await owner.call('send',{...req('','','unauthorized'),target:'chat',target_type:'chat_id',metadata})).ok,false);
  }
  assert.equal(sends,0,'unscoped send reached provider HTTP');
  const invalidLease=await owner.call('create',req()); assert.equal(invalidLease.ok,true);
  for (const provider of ['fixture','codex']) {
   const spoof=await owner.call('send',{...req(invalidLease.stream_generation,'','spoof',{creation_token:invalidLease.creation_token}),provider,target:'chat',target_type:'chat_id'});
   assert.equal(spoof.ok,false); assert.equal(spoof.error,'feishu_bridge_provider_mismatch');
  }
  emptySend=true;
  const invalidSend={...req(invalidLease.stream_generation,'','blank-result',{creation_token:invalidLease.creation_token}),target:'chat',target_type:'chat_id'};
  assert.equal((await owner.call('send',invalidSend)).ok,false,'empty provider ID was reported as committed');
  const afterEmpty=sends;
  assert.equal((await owner.call('send',invalidSend)).ok,false); assert.equal(sends,afterEmpty,'failed send reused spent credential');
  const lease = await owner.call('create', req()); assert.equal(lease.ok,true);
  const sent = await owner.call('send', {...req(lease.stream_generation,'','initial',{creation_token:lease.creation_token}),target:'chat',target_type:'chat_id'}); assert.equal(sent.ok,true);
  const id=sent.message_id;
  const bound=await owner.call('bind',req(sent.stream_generation,id,'',{source_stream:'wire',source_app:'main'})); assert.equal(bound.ok,true);
  assert.notEqual(bound.stream_generation,sent.stream_generation);
  let count=patches.length;
  assert.equal((await owner.call('update',req(sent.stream_generation,id,'late-old'))).ok,false);
  assert.equal(patches.length,count,'retired generation reached HTTP');
  for (const generation of ['', 'missing']) assert.equal((await owner.call('update',req(generation,id))).ok,false);
  assert.equal((await owner.call('update',{...req(bound.stream_generation,id),instance:'other'})).ok,false);
  const foreign=await peer('foreign');
  assert.equal((await foreign.call('update',req(bound.stream_generation,id))).ok,false,'foreign physical connection updated a resource');
  assert.equal(patches.length,count);
  assert.equal((await owner.call('append',req(bound.stream_generation,id,'captured {{content}}'))).ok,true);
  const templateResult=await owner.call('update',req(bound.stream_generation,id,'template {{content}}',{feishu_update_captured_content:'forged mirror'}));
  assert.equal(templateResult.ok,true,JSON.stringify(templateResult));
  assert.equal(JSON.parse(JSON.parse(patches.at(-1)).content).elements[0].content,'template initialcaptured {{content}}','owner snapshot was not rendered exactly once');
  assert.ok(!patches.at(-1).includes('forged mirror'),'wire metadata replaced owner content');
  for (let i=0;i<2;i++) {
   const result=await owner.call('update',req(bound.stream_generation,id,'whole-card-' + i));
   assert.equal(result.ok,true,JSON.stringify(result)); assert.equal(result.stream_generation,bound.stream_generation); assert.equal(result.stream_state,'message');
  }
  assert.equal((await owner.call('append',req(bound.stream_generation,id,'old stream revival'))).ok,false);
  await owner.call('clear',req(bound.stream_generation));
  count=patches.length;
  assert.equal((await owner.call('update',req(bound.stream_generation,id,'after revoke'))).ok,false);
  assert.equal(patches.length,count);
  const bindFresh = async p => {
   const grant=await p.call('create',req('',id)); assert.equal(grant.ok,true);
   const result=await p.call('bind',req('',id,'',{creation_generation:grant.stream_generation,creation_token:grant.creation_token,source_stream:'wire',source_app:'main'}));
   assert.equal(result.ok,true,JSON.stringify(result)); return result;
  };
  const old=await bindFresh(owner);
  hold=true;
  const delayed=owner.call('update',req(old.stream_generation,id,'held-old'), 'held-update', 4000).catch(()=>null);
  await until(()=>release);
  owner=await peer('owner'); // exact socket retirement withdraws the original claim
  const fresh=await bindFresh(owner); assert.notEqual(fresh.stream_generation,old.stream_generation);
  assert.equal((await owner.call('append',req(fresh.stream_generation,id,'fresh-only'))).ok,true);
  release(); release=undefined;
  const late=await delayed; if(late) assert.equal(late.ok,false);
  assert.equal((await owner.call('append',req(fresh.stream_generation,id,' + after-late'))).ok,true,'old completion sealed or removed the successor');
  const finish=await owner.call('finish',req(fresh.stream_generation,id,'{{content}}')); assert.equal(finish.ok,true); assert.equal(finish.stream_state,'sealed');
  assert.ok(patches.some(body=>body.includes('fresh-only + after-late')), 'successor content was lost to old update completion');
  count=patches.length;
  assert.equal((await owner.call('update',req(old.stream_generation,id,'late replay'))).ok,false); assert.equal(patches.length,count);
  const grant=await owner.call('create',req()); assert.equal(grant.ok,true);
  const pendingRequest={...req(grant.stream_generation,'','held-send',{creation_token:grant.creation_token}),target:'chat',target_type:'chat_id'};
  holdSend=true;
  const pendingSend=owner.call('send',pendingRequest,'held-raw-send',4000).catch(()=>null);
  await until(()=>typeof releaseSend==='function');
  const replacement=await peer('owner');
  const afterSend=await bindFresh(replacement);
  assert.equal((await replacement.call('append',req(afterSend.stream_generation,id,'new after send'))).ok,true);
  releaseSend(id); await pendingSend;
  assert.equal((await replacement.call('append',req(afterSend.stream_generation,id,' + retained'))).ok,true,'late send took over replacement');
  const beforeReplay=sends;
  for (const metadata of [pendingRequest.metadata,{...pendingRequest.metadata,stream_id:''},{}]) {
   assert.equal((await replacement.call('send',{...pendingRequest,metadata})).ok,false);
  }
  assert.equal(sends,beforeReplay,'old send replay reached HTTP');
  assert.equal((await replacement.call('finish',req(afterSend.stream_generation,id,'{{content}}'))).ok,true);
  assert.ok(patches.some(body=>body.includes('new after send + retained')),'late send erased successor content');

  await replacement.call('clear',req(afterSend.stream_generation)); assert.equal(child.exitCode,null,output);
 } catch(error) { console.error(error.stack);console.error(output.slice(-6000));throw error; }
 finally {
  if(release) release();
  for(const ws of sockets) ws.close();
  if(child && child.exitCode===null){child.kill('SIGTERM');const timer=setTimeout(()=>child.kill('SIGKILL'),7000);await done;clearTimeout(timer);}
  await new Promise(r=>api.close(r)); fs.rmSync(root,{recursive:true,force:true});
 }
});
