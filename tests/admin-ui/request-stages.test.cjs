const test=require('node:test'),assert=require('node:assert/strict');
const {stages}=require('../../admin/ui/traffic-requests.js');
test('stage diagnosis distinguishes queued work, actual vjsx and outlet processing',()=>{
 const base={available:true,queue_observed:true,vjsx_observed:true,adapter_observed:true,queue_ms:800,vjsx_ms:120,adapter_ms:10,other_ms:20};
 let model=stages(base);assert.match(model.bottleneck,/排队/);assert.equal(model.rows.length,4);assert(Math.abs(model.rows.reduce((n,r)=>n+r.share,0)-100)<1e-8);
 assert.match(stages({...base,queue_ms:1,adapter_ms:900}).bottleneck,/出口 Adapter/);
 assert.match(stages({...base,queue_ms:1,vjsx_ms:950}).bottleneck,/vjsx 执行/);
 assert.match(stages({...base,other_ms:2000}).bottleneck,/未细分/);
});
test('unsupported stages stay unknown and invalid or legacy data cannot claim zero delay',()=>{
 const m=stages({available:true,queue_observed:false,vjsx_observed:false,adapter_observed:true,adapter_ms:2,other_ms:1});
 assert.equal(m.rows[0].measured,false);assert.equal(m.rows[1].measured,false);assert.match(m.bottleneck,/出口/);
 for(const input of [null,{}, {available:true,queue_observed:true,queue_ms:-1}])assert.equal(stages(input).available,false);
});
