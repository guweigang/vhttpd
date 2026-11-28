import test from 'node:test';
import assert from 'node:assert/strict';
import {createCodexApprovalRouter} from '../lib/approval-router.mjs';
function setup(lastEvent) {
  const changes=[];
  const state={requestId:'key',rpcRequestId:'1',parentStreamId:'parent',approvalStreamId:'approval',codexInstance:'main',turnId:'turn',status:'pending',payload:{method:'item/commandExecution/requestApproval',params:{}}};
  const router=createCodexApprovalRouter({
    getApprovalRequestState:async()=>state,
    getStreamState:async()=>({streamId:'parent',turnId:'turn',lastEvent}),
    upsertApprovalRequestState:async(_,patch)=>changes.push(patch),
    updateStreamState:async(_,patch)=>changes.push(patch),
    codexRpcReply:(...args)=>({type:'reply',args}),
  });
  return {router,changes};
}
const inbound={actionValue:{kind:'codex_approval',requestId:'key',decision:'cancel'}};
const frame={instance:'main',runtime:{log(){},warn(){}}};
test('a stale card for an interrupted turn closes without replying to a new connection',async()=>{
  const {router,changes}=setup('turn/completed');
  const result=await router.handleApprovalAction(inbound,frame);
  assert.equal(result.handled,true);assert.deepEqual(result.commands,[]);
  assert.equal(changes[0].status,'resolved');
  assert.equal(JSON.parse(result.response.body).card.type,'raw');
});
test('an active approval click replies to Codex and returns the current Feishu card envelope',async()=>{
  const {router,changes}=setup('turn/started');
  const result=await router.handleApprovalAction(inbound,frame);
  assert.equal(result.commands.length,1);
  assert.deepEqual(result.commands[0].args[1],{decision:'cancel'});
  assert.equal(changes[0].status,'decided');
  assert.equal(JSON.parse(result.response.body).card.type,'raw');
});
