import {storageChecks} from './storage-e2e-checks.mjs';
import {assert} from './support.mjs';
if (process.release?.name !== 'vjsx') throw Error('Use vjsx');
const base=process.env.WCF_BASE_URL;
async function request(name,data={},token) {
  const response=await fetch(base+name,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(data),signal:AbortSignal.timeout(15000)});
  return {status:response.status,body:await response.json()};
}
let ready=false;
for(let i=0;i<600;i++) {
  try {const response=await request('/auth/login',{code:'bad'});if(response.status===401){ready=true;break;}}catch(_){}
  await new Promise(resolve=>setTimeout(resolve,250));
}
assert.ok(ready,'MySQL fixture server did not become ready');
const alice=(await request('/auth/login',{code:'alice'})).body.token;
const bob=(await request('/auth/login',{code:'bob'})).body.token;
const action=async(token,action,extra={})=>{
  const response=await request('/functions/cloudContract',{action,...extra},token);
  assert.equal(response.status,200,action+': '+JSON.stringify(response.body));return response.body.result;
};
await storageChecks(base,alice,bob);
await action(alice,'seed');await action(bob,'seed');
await Promise.all(Array.from({length:8},()=>action(alice,'inc')));
const doc=await action(alice,'read');assert.equal(doc.visits,8);assert.equal(doc.nested.count,17);
const query=await action(alice,'query');assert.equal(query.data.length,1);assert.equal(query.count.total,1);assert.equal(query.missing,2);
const operators=await action(alice,'operators');
assert.equal(operators.either,2);assert.equal(operators.member,1);assert.equal(operators.excluded,1);assert.equal(operators.unequal,1);assert.equal(operators.array,2);assert.equal(operators.mixedType,0);
assert.equal(operators.doc.nested.other,undefined);assert.equal(operators.doc.nested.label,'safe');
assert.equal(await action(alice,'tx'),8);assert.equal((await action(alice,'read')).visits,18);
assert.equal((await request('/functions/cloudContract',{action:'tx',fail:true},alice)).status,500);
assert.equal((await action(alice,'read')).visits,18);
assert.equal((await request('/functions/cloudContract',{action:'ordinaryFailure'},alice)).status,500);
assert.equal((await action(alice,'read')).visits,19);
const value="中文 O'Reilly \\'; DROP TABLE wcf_documents; --";
await action(alice,'add',{value});assert.equal((await action(alice,'injection',{value})).data.length,1);
assert.equal((await action(alice,'remove')).stats.removed,2);assert.equal((await action(bob,'read')).visits,0);
assert.equal((await request('/functions/cloudContract',{action:'read'})).status,401);
console.log('PASS MySQL 8.0: login, concurrent updates, JSON operators, rollback, ordinary commits, UTF-8/injection binding, counts and user isolation (vjsx)');
