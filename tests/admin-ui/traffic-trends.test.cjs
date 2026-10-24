const test=require('node:test'),assert=require('node:assert/strict');
require('../../admin/ui/overview.js');const {build,status}=require('../../admin/ui/traffic-trends.js');
const metric=(requests,errors=0,ms=10)=>({requests_total:requests,errors_total:errors,client_errors_total:0,server_errors_total:errors,timeouts_total:0,duration_count:requests,duration_sum_ms:requests*ms,duration_max_ms:requests?ms:0,duration_buckets:[0,0,0,0,0,requests,requests,requests,requests]});
function fixture(){
 const business={available:true,listeners:[{id:'web',metrics:metric(100,20),routes:[{id:'fast',metrics:metric(90,20)},{id:'slow',metrics:metric(10)}]}],routes:[{id:'fast',listener:'web',metrics:metric(90,20)},{id:'slow',listener:'web',metrics:metric(10)}]};
 const snapshot={at_unix:1060,start_unix:1000,window_seconds:60,listener:'',pipeline:'',route_filtered:false,metrics:metric(10,1),listeners:[{listener_id:'web',metrics:metric(10,1),routes:[{pipeline_id:'fast',metrics:metric(9,1)},{pipeline_id:'slow',metrics:metric(1,0,1200)}]}],series:[{at_unix:1000,span_seconds:10,metrics:metric(8,1)},{at_unix:1010,span_seconds:10,metrics:metric(0)},{at_unix:1020,span_seconds:10,metrics:metric(2)}]};
 return {business,snapshot};
}
test('rates use server window durations and show idle latency/error-rate as missing',()=>{
 const {business,snapshot}=fixture(),m=build(snapshot,business,{},1060);
 assert.equal(m.rps,10/60);assert.equal(m.errorRate,10);assert.equal(m.points[0].requests,.8);assert.equal(m.points[1].errorRate,null);assert.equal(m.points[1].average,null);assert.equal(m.points[1].requests,0);
});
test('window selection and server identity cannot show stale or wrong-filter charts',()=>{
 const {business,snapshot}=fixture();
 for(const [filter,now] of [[{listener:'other'},1060],[{pipeline:'fast'},1060],[{seconds:300},1060],[{},1080]])assert.equal(build(snapshot,business,filter,now).available,false);
 const missing=build(null,business,{},1060);assert.equal(missing.historicalIssues,0);assert.equal(missing.rows[0].status,'近期未确认');
});
test('history never keeps a route unhealthy after the recent errors have expired',()=>{
 const {business,snapshot}=fixture();snapshot.listeners[0].routes[0].metrics=metric(4);
 let m=build(snapshot,business,{status:'history'},1060);assert.equal(m.rows.length,1);assert.match(m.rows[0].status,/近期无错误/);
 snapshot.listeners[0].routes[0].metrics=metric(0);
 m=build(snapshot,business,{status:'history'},1060);assert.match(m.rows[0].status,/未确认恢复/);
 assert.equal(status(metric(0),metric(10,3),500),'近期无请求 · 有历史错误，未确认恢复');
});
test('slow routing uses recent maximum, supports thresholds and keeps historical maximum separate',()=>{
 const {business,snapshot}=fixture();business.routes[0].metrics.duration_max_ms=50000;
 const m=build(snapshot,business,{status:'slow',sort:'slow',slowMs:500},1060);
 assert.deepEqual(m.rows.map(row=>row.id),['slow']);assert.equal(build(snapshot,business,{status:'slow',slowMs:1500},1060).rows.length,0);
 assert.deepEqual(build(snapshot,business,{sort:'requests'},1060).rows.map(row=>row.id),['fast','slow']);
});
test('startup coverage is explicit and uses actual coverage, not the entire selected window',()=>{
 const {business,snapshot}=fixture();snapshot.start_unix=1050;
 const m=build(snapshot,business,{},1060);assert.equal(m.warmup,true);assert.equal(m.span,10);assert.equal(m.rps,1);
});
