const test=require('node:test');
const assert=require('node:assert/strict');
const {build}=require('../../admin/ui/overview.js');
function fixture(){return {
 configFiles:[{role:'main',path:'/projects/hello/vhttpd.toml'},{role:'include',path:'/projects/hello/routes.toml',include_path:'./routes.toml'}],
 runtime:{uptime_seconds:61,pipelines:{listener_id:'admin'},listeners:[{listener_id:'admin',is_control:true},{listener_id:'web',is_control:false,http_metrics:{requests_total:0,errors_total:0,client_errors_total:0,server_errors_total:0,timeouts_total:0,duration_sum_ms:0,duration_count:0,duration_max_ms:0,duration_buckets:[]}}],relay:{agents:[]}},
 stats:{http:{requests_total:0,errors_total:0,timeouts_total:0}},
 plan:{config_path:'/projects/hello/vhttpd.toml',allowed:true,actions:[],strategy:'lightweight'},
 graph:{nodes:[{id:'admin',ref:'listener:admin',domain:'listener'},{id:'web',ref:'listener:web',domain:'listener',metadata:{host:'127.0.0.1',port:'8000'}},{id:'hello',ref:'pipeline:hello',domain:'pipeline',metadata:{methods:'GET',paths:'/hello'}},{id:'out',ref:'adapter:out',domain:'adapter'},{id:'app',ref:'engine:app',domain:'engine',kind:'vjsx'}],edges:[{from:'listener:web',to:'pipeline:hello',kind:'ingress'},{from:'pipeline:hello',to:'adapter:out',kind:'egress'},{from:'adapter:out',to:'engine:app',kind:'adapter_uses_engine'}]}};}
test('overview connects input, route, outlet and engine without mistaking configured for live',()=>{
 const f=fixture(),m=build(f);
 assert.equal(m.project,'hello');assert.equal(m.states[1].title,'1 / 1 已登记');
 assert.match(m.states[2].title,/一致/);assert.match(m.states[2].detail,/业务行为需实际请求/);
 assert.deepEqual(m.chains[0].steps.map(s=>s.ref),['listener:web','pipeline:hello','adapter:out','engine:app']);
 assert.equal(m.chains[0].match,'GET · /hello');
 f.runtime.listeners=[];assert.equal(build(f).states[1].title,'0 / 1 已登记');
});
test('failed or missing telemetry is unknown rather than healthy zero',()=>{
 const f=fixture();delete f.stats;delete f.runtime.stats;delete f.runtime.listeners[1].http_metrics;
 assert.equal(build(f).metrics[0].value,'—');
 assert.equal(build(fixture()).metrics[0].value,0);
 const failed=build(fixture(),{runtime:'offline',stats:'offline'});
 assert.equal(failed.metrics[0].value,'—');assert.equal(failed.states[2].title,'未确认');
 assert.equal(failed.states[1].title,'未确认');
});
test('whole-project plan needs valid identity and evidence, pending points to Mac restart',()=>{
 const f=fixture();f.plan.actions=['restart_listener'];f.plan.restart_listeners=['web'];
 assert.equal(build(f).states[2].title,'待重启生效');assert.match(build(f).notices[0].detail,/Mac 工作台/);
 for(const plan of [null,{}, {...f.plan,config_path:'/foreign/vhttpd.toml'},{...f.plan,actions:null}]) {
  assert.equal(build({...f,plan}).states[2].title,'未确认');
 }
});
test('disconnected Relay and cumulative errors give scoped actions without leaking secrets',()=>{
 const f=fixture();f.runtime.relay.agents=[{node_id:'edge',state:'backoff',last_error:'secret-token'}];f.stats.http.errors_total=3;
 const m=build(f);assert.equal(m.notices[0].view,'relay');assert.equal(m.notices.length,1);
 assert.equal(m.metrics[1].value,'0 / 0');assert(!JSON.stringify(m).includes('secret-token'));
 assert.match(m.metrics[0].detail,/不含管理接口/);
});
test('auth failure hides stale values and avoids flooding the user with endpoint errors',()=>{
 const m=build(fixture(),{runtime:'403',graph:'403',stats:'403',events:'403'},true);
 assert.equal(m.notices.length,1);assert.equal(m.chains.length,0);assert.equal(m.metrics[0].value,'—');assert.equal(m.sources.length,0);
});
test('recent operations show newest first and keep include sources discoverable',()=>{
 const f=fixture();f.events=Array.from({length:8},(_,i)=>({ts:String(i),type:'publish',key:'draft'+i}));
 const m=build(f);assert.deepEqual(m.events.map(e=>e.time),['7','6','5','4','3']);assert.equal(m.sources[1].label,'./routes.toml');
});
test('persisted events use their actual Unix time and nested draft fields',()=>{
 const f=fixture();f.events=[{at_unix:1792294657,type:'admin.config_changeset.published',fields:{draft_id:'project.edit',token:'must-not-leak'}}];
 const event=build(f).events[0];assert.notEqual(event.time,'—');assert.equal(event.type,'已发布项目配置');assert.equal(event.target,'project.edit');assert(!JSON.stringify(event).includes('must-not-leak'));
});
test('business aggregation excludes control polling and merges histogram buckets across listeners',()=>{
 const f=fixture();const metrics={requests_total:20,errors_total:2,client_errors_total:1,server_errors_total:1,timeouts_total:1,duration_sum_ms:1000,duration_count:20,duration_max_ms:250,duration_buckets:[0,0,0,18,19,20,20,20,20],last_status:200};
 f.runtime.listeners[0].http_metrics={...metrics,requests_total:10000};
 f.runtime.listeners[1].http_metrics=metrics;f.runtime.listeners[1].pipelines={routes:[{pipeline_id:'hello',methods:['GET'],paths:['/hello']},{pipeline_id:'idle'}]};f.runtime.listeners[1].route_metrics=[{pipeline_id:'hello',metrics}];
 f.runtime.listeners.push({listener_id:'second',is_control:false,http_metrics:{...metrics,duration_sum_ms:2000}});
 f.configFiles[1].pipeline_ids=['hello'];
 const m=build(f);assert.equal(m.business.total.requests_total,40);assert.equal(m.business.total.errors_total,4);assert.equal(m.business.latency.average,'75.0 ms');assert.equal(m.business.latency.p95,'≤ 100 ms');
 assert.equal(m.business.routes[0].source,'/projects/hello/routes.toml');assert.equal(m.business.routes[1].metrics.requests_total,0);
 assert.equal(m.business.routes[0].metrics.last_status,200);assert.equal(m.business.routes[0].issue,true);
});
test('missing listener counters remain unknown and mixed control/data listeners stay included',()=>{
 const f=fixture();f.runtime.pipelines.listener_id='web';assert.equal(build(f).business.listeners.length,1);
 delete f.runtime.listeners[1].http_metrics;
 assert.equal(build(f).business.available,false);assert.equal(build(f).metrics[0].value,'—');
});

test('overview only flags fresh recent errors, never cumulative history or stale snapshots',()=>{
 const f=fixture();f.runtime.listeners[1].http_metrics.errors_total=42;
 const trafficNotices=()=>build(f).notices.filter(item=>item.view==='traffic');
 assert.equal(trafficNotices().length,0);
 f.traffic={at_unix:Math.floor(Date.now()/1000),window_seconds:60,listeners:[{routes:[{pipeline_id:'hello',metrics:{errors_total:1}}]}]};
 assert.equal(trafficNotices().length,1);assert.match(trafficNotices()[0].title,/近期窗口/);
 f.traffic.listeners[0].routes[0].metrics.errors_total=0;assert.equal(trafficNotices().length,0);
 f.traffic.listeners[0].routes[0].metrics.errors_total=1;f.traffic.at_unix-=30;assert.equal(trafficNotices().length,0);
});
