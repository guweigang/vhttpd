const test=require('node:test'),assert=require('node:assert/strict');
const {select}=require('../../admin/ui/traffic-requests.js');
const sample=(id,at,duration)=>({request:{observation_id:id,at_unix:at,duration_ms:duration,status:200,method:'GET'},log_line:'[http.observation] '+id});
const fixture=()=>({listener:'web',pipeline:'slow',window_seconds:60,at_unix:1000,retained:50,requests:[sample('old',939,900),sample('fast',990,10),sample('slow',995,700),sample('future',1001,900),sample('slower',999,1200)]});
test('slow details use exact route/window, threshold and newest-first bounded records',()=>{
 const model=select(fixture(),['web','slow'],60,500,1000);
 assert.equal(model.available,true);assert.equal(model.retained,50);assert.deepEqual(model.requests.map(r=>r.observation_id),['slower','slow']);assert.equal(model.requests[1].duration_ms,700);assert.match(model.requests[0].log_line,/slower/);
 assert.equal(select(fixture(),['web','slow'],60,1500,1000).requests.length,0);
});
test('stale responses, other routes/listeners and failed loads never appear as empty healthy results',()=>{
 for(const [focus,seconds,now] of [[['other','slow'],60,1000],[['web','other'],60,1000],[['web','slow'],300,1000],[['web','slow'],60,1020]])assert.equal(select(fixture(),focus,seconds,500,now).available,false);
 assert.equal(select(null,['web','slow'],60,500,1000).available,false);
});
