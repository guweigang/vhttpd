const test=require('node:test'),assert=require('node:assert/strict');
const {build,forRoute}=require('../../admin/ui/executor-overview.js');
const fixture=()=>({at_unix:1000,instances:[{listener_id:'web',pool:'app',primary:false,kind:'vjsx',engine_ids:['app'],routes:[{pipeline_id:'one',adapter_id:'out'},{pipeline_id:'two',adapter_id:'out'}],load:{available:true,embedded:true,concurrency_observed:true,capacity:2,occupied:2,inflight:2,usable:2,waiting:3,queue_timeouts_total:8,last_queue_timeout_unix:990}},{listener_id:'other',pool:'app',routes:[{pipeline_id:'one'}],engine_ids:['app'],load:{available:true,capacity:1,occupied:0,waiting:0,usable:1}}]});
test('busy state and shared routes are scoped to the actual listener instance',()=>{
 const m=build(fixture(),[{path:'engines.toml',engine_ids:['app']},{path:'routes.toml',pipeline_ids:['one','two'],adapter_ids:['out']}],1000);
 assert.equal(m.instances[0].status,'正在排队');assert.equal(m.instances[1].status,'采样时空闲');
 assert.equal(forRoute(m,'web','one').length,1);assert.equal(forRoute(m,'web','one')[0].routes.length,2);assert.equal(m.instances[0].engineSources[0].path,'engines.toml');assert.deepEqual(m.instances[0].routes[0].sources,['routes.toml']);assert(m.instances[0].recentTimeout);
});
test('historical timeouts do not label an idle executor currently busy',()=>{
 const f=fixture();Object.assign(f.instances[0].load,{waiting:0,occupied:0,last_queue_timeout_unix:100});
 const item=build(f,[],1000).instances[0];assert.equal(item.status,'采样时空闲');assert.equal(item.recentTimeout,false);assert.equal(item.load.queue_timeouts_total,8);
});
test('missing, stale and unsupported concurrency are unknown rather than healthy zero',()=>{
 assert.equal(build(null,[],1000).available,false);assert.equal(build(fixture(),[],1020).available,false);
 const f=fixture();f.instances[0].load={available:true,concurrency_observed:false,waiting:0,capacity:3};assert.equal(build(f,[],1000).instances[0].status,'并发占用未确认');
 f.instances[0].load={available:false};assert.equal(build(f,[],1000).instances[0].status,'负载未采集');
});
test('unusable or retiring vjsx slots do not appear idle',()=>{
 const f=fixture();Object.assign(f.instances[0].load,{waiting:0,occupied:0,usable:0});assert.equal(build(f,[],1000).instances[0].status,'无可接收的执行槽');
 f.instances[0].load.stopping=true;assert.equal(build(f,[],1000).instances[0].status,'停止接收');
});
