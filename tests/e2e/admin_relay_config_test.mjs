import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import '../../admin/ui/relay-config.js';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const binary = process.env.VHTTPD_BIN || path.join(repo,'vhttpd');
const delay = ms => new Promise(r=>setTimeout(r,ms));
async function port() { const s=net.createServer(); await new Promise(r=>s.listen(0,'127.0.0.1',r)); const p=s.address().port; await new Promise(r=>s.close(r)); return p; }
async function until(fn) { for(let i=0;i<120;i++){ try{const result=await fn();if(result)return result;}catch{} await delay(100); } throw new Error('timed out'); }

for (const includeMode of [false, true]) test((includeMode ? 'Nested include: ' : 'Main config: ') + 'Relay draft → project validation → publish → restart → end-to-end response', {timeout:60000}, async()=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'vhttpd-relay-editor-'));
  const allocated=new Set(); async function nextPort(){let p; do{p=await port();}while(allocated.has(p));allocated.add(p);return p;}
  const hubPort=await nextPort(), hubWeb=await nextPort(),hubAdmin=await nextPort(),agentWeb=await nextPort(),agentAdmin=await nextPort();
  const token='relay-editor-local-test';
  const children=[];
  const head=(name,web,admin)=>`version = 2\n[server]\npid_file = "${root}/${name}.pid"\n[observability]\nevent_log = "${root}/${name}.ndjson"\n[listeners.web]\nprotocol = "http"\ntransport = "tcp"\nhost = "127.0.0.1"\nport = ${web}\n[listeners.admin]\nprotocol = "http"\ntransport = "tcp"\nhost = "127.0.0.1"\nport = ${admin}\n[control]\nlistener = "listener:admin"\ntoken = "${token}"\n`;
  const hubPath=path.join(root,'hub.toml'), agentPath=path.join(root,'agent.toml');
  const hubBase=head('hub',hubWeb,hubAdmin)+`[listeners.relay]\nprotocol="websocket"\ntransport="tcp"\nhost="127.0.0.1"\nport=${hubPort}\n[relays.edge]\nmode="hub"\ncarrier="websocket"\nlistener="listener:relay"\npath="/vhttpd/relay"\nnode_id="hub-before"\ntoken="pair-test"\n[adapters.reply]\nkind="fixed-response"\noptions.body="before"\n[[pipelines]]\nid="public/relay"\ningress="listener:web"\nmatch.paths=["/relay"]\negress="adapter:reply"\n`;
  const agentBase=head('agent',agentWeb,agentAdmin)+`[adapters.reply]\nkind="fixed-response"\noptions.status="200"\noptions.body="relay editor roundtrip"\n[[pipelines]]\nid="relay/response"\ningress="listener:web"\negress="adapter:reply"\n[[pipelines]]\nid="health"\ningress="listener:web"\nmatch.paths=["/health"]\negress="adapter:reply"\n`;
  let hubSource=hubPath, agentSource=agentPath, hubEditorBase=hubBase, agentEditorBase=agentBase;
  let hubRoot=hubBase, agentRoot=agentBase;
  if(includeMode){
    const makeSources=(name,base)=>{
      const dir=path.join(root,name);fs.mkdirSync(path.join(dir,'nested'),{recursive:true});
      const source=path.join(dir,'nested','relay.toml');
      const group=path.join(dir,'group.toml');fs.writeFileSync(group,'include=["nested/relay.toml"]\n');
      const relayStart=base.indexOf('[relays.edge]'), adapterStart=base.indexOf('[adapters.reply]'), pipelineStart=base.indexOf('[[pipelines]]');
      const relayBlock=relayStart<0?'':base.slice(relayStart,adapterStart);
      const adapters=base.slice(adapterStart,pipelineStart);
      const healthStart=base.indexOf('[[pipelines]]',pipelineStart+1);
      const fragment=relayBlock+base.slice(pipelineStart,healthStart<0?undefined:healthStart);
      const entry=base.slice(0,relayStart<0?adapterStart:relayStart).replace('version = 2','version = 2\ninclude=["'+name+'/group.toml"]')+adapters+(healthStart<0?'':base.slice(healthStart));
      fs.writeFileSync(source,fragment);return {source,fragment,entry};
    };
    const h=makeSources('hub-config',hubBase),a=makeSources('agent-config',agentBase);
    hubSource=h.source;agentSource=a.source;hubEditorBase=h.fragment;agentEditorBase=a.fragment;hubRoot=h.entry;agentRoot=a.entry;
  }
  fs.writeFileSync(hubPath,hubRoot);fs.writeFileSync(agentPath,agentRoot);
  async function start(config,admin){ const child=spawn(binary,['--config',config],{cwd:repo,stdio:['ignore','pipe','pipe']});let log='';child.stderr.on('data',d=>log+=d);child.stdout.on('data',d=>log+=d);children.push(child);try { await until(async()=>{if(child.exitCode!==null)throw new Error(log);return (await fetch(`http://127.0.0.1:${admin}/admin/runtime`,{signal:AbortSignal.timeout(2000),headers:{'x-vhttpd-admin-token':token}})).ok;}); } catch(e) { throw new Error(e.message+'\n'+log); } return child; }
  async function stop(child){ if(child.exitCode!==null)return;const done=new Promise(r=>child.once('exit',r));child.kill('SIGTERM');await done; }
  const request=async(admin,url,options={})=>{const r=await fetch(`http://127.0.0.1:${admin}`+url,{...options,headers:{'x-vhttpd-admin-token':token,...options.headers}});const body=await r.json();assert(r.ok,JSON.stringify(body));return body;};
  const common={id:'edge',carrier:'websocket',token:'pair-test',max_channels:1024,channel_buffer:64,reconnect_delay_ms:100};
  async function publish(admin,config,source,text){
    const saved=await request(admin,'/admin/drafts?id=relay-edit&config_source='+encodeURIComponent(source),{method:'POST',body:text});assert.equal(saved.key,'relay-edit');
    const validation=await request(admin,'/admin/drafts/relay-edit/validate',{method:'POST'});assert.equal(validation.ok,true,JSON.stringify(validation));
    const diff=await request(admin,'/admin/drafts/relay-edit/diff');assert.equal(diff.strategy,'relay_reload_required');
    const result=await request(admin,'/admin/source/drafts/relay-edit/publish?path='+encodeURIComponent(source),{method:'POST'});assert.equal(result.ok,true);assert.equal(fs.readFileSync(source,'utf8'),text);
    const preview=await request(admin,'/admin/runtime/plan/replacement?config='+encodeURIComponent(config));assert.equal(preview.allowed,false);
    return preview;
  }
  try{
    let hub=await start(hubPath,hubAdmin),agent=await start(agentPath,agentAdmin);
    const hubText=RelayConfig.update(hubEditorBase,{...common,mode:'hub',node_id:'hub-test',listener:'listener:relay',path:'/vhttpd/relay'}, {pipeline:'public/relay',direction:'outgoing',route:'relay/response'}, {fragment:includeMode});
    const agentText=RelayConfig.update(agentEditorBase,{...common,mode:'agent',node_id:'agent-test',url:`ws://127.0.0.1:${hubPort}/vhttpd/relay`,autostart:true}, {pipeline:'relay/response',direction:'incoming',egress:'adapter:reply'}, {fragment:includeMode});
    // Failed validation must leave disk and runtime untouched.
    await request(agentAdmin,'/admin/drafts?id=bad&config_source='+encodeURIComponent(agentSource),{method:'POST',body:agentText.replace('egress = "adapter:reply"','egress = "adapter:missing"')});
    const invalidResponse=await fetch(`http://127.0.0.1:${agentAdmin}/admin/drafts/bad/validate`,{method:'POST',headers:{'x-vhttpd-admin-token':token}}); assert.equal(invalidResponse.status,422); const invalid=await invalidResponse.json();assert.equal(invalid.ok,false);
    assert.equal(fs.readFileSync(agentPath,'utf8'),agentRoot);
    if(includeMode){
      const files=await request(hubAdmin,'/admin/config/files');assert.equal(files.length,3);
      const declared=files.find(f=>f.path===hubSource);assert.deepEqual(declared.relay_ids,['edge']);
      assert.equal(declared.parent_path,path.join(root,'hub-config','group.toml'));
    }
    await publish(hubAdmin,hubPath,hubSource,hubText);await publish(agentAdmin,agentPath,agentSource,agentText);
    if(includeMode){assert.equal(fs.readFileSync(hubPath,'utf8'),hubRoot);assert.equal(fs.readFileSync(agentPath,'utf8'),agentRoot);}
    await stop(hub);await stop(agent);
    hub=await start(hubPath,hubAdmin);agent=await start(agentPath,agentAdmin);
    await until(async()=>{const runtime=await request(agentAdmin,'/admin/runtime');return runtime.relay.agents.some(a=>a.state==='registered');});
    const response=await until(async()=>{const r=await fetch(`http://127.0.0.1:${hubWeb}/relay`);const text=await r.text();return text==='relay editor roundtrip'&&r.status===200;});assert(response);
    for(const [admin,config] of [[hubAdmin,hubPath],[agentAdmin,agentPath]]){
      const preview=await request(admin,'/admin/runtime/plan/replacement?config='+encodeURIComponent(config));assert.equal(preview.allowed,true);assert.equal(preview.actions.length,0);
    }
  }finally{await Promise.all(children.map(stop));fs.rmSync(root,{recursive:true,force:true});}
});
