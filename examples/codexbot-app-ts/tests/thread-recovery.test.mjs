import {recoveryHarness} from './helpers/thread-recovery-harness.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {createThreadTaskCommandHandlers} from '../lib/thread-task-commands.mjs';
import {isBusyStreamStatus} from '../lib/busy-guard.mts';
test('every saved-thread task resumes metadata before starting a turn',async()=>{
  const h=recoveryHarness();h.stream.status='completed';
  const handlers=createThreadTaskCommandHandlers({...h.deps,isBusyStream:()=>false,isStaleBusyStream:()=>false,
    getProjectRecord:async()=>({}),createStreamState:async()=>{h.stream.status='queued';return {...h.stream};},
    ensureStreamCodexInstance:async(s)=>s,buildCodexPreflightCommands:async()=>[],resolveCodexInstance:async()=> 'main'});
  const response=await handlers.handleRegularTask({sessionKey:'chat',chatId:'chat'},h.stream.prompt);
  assert.equal(response.commands[0].method,'thread/resume');
  assert.equal(response.commands[0].params.threadId,'old');
  assert.equal(response.commands[0].params.excludeTurns,true);
  assert.equal(h.stream.status,'resuming_thread');assert.ok(isBusyStreamStatus(h.stream.status));
});
test('resume preserves the ID and starts the original prompt exactly once',async()=>{
  const h=recoveryHarness();
  assert.deepEqual(await h.coordinator.continueQueuedTurnStart('s','old'),[]);
  assert.equal(h.calls.binds,0);
  const result=await h.respond('thread/resume',{thread:{id:'old',path:'/history'}});
  assert.equal(result.commands.length,1);assert.equal(result.commands[0].method,'turn/start');
  assert.equal(result.commands[0].params.threadId,'old');assert.equal(result.commands[0].params.input[0].text,h.stream.prompt);
  assert.equal(h.chat.threadId,'old');assert.equal(h.calls.resets,0);
  assert.deepEqual((await h.respond('thread/resume',{thread:{id:'old'}})).commands,[]);
});
test('only an explicit missing rollout on resume permits creating a replacement thread',async()=>{
  const h=recoveryHarness();const error={code:-32600,message:'no rollout found for thread id old'};
  const result=await h.respond('thread/resume',error,error);
  assert.equal(h.calls.resets,1);assert.equal(result.commands[1].method,'thread/start');
  assert.equal(h.stream.status,'queued');
  const started=await h.respond('thread/start',{thread:{id:'replacement'}});
  assert.equal(started.commands[0].method,'turn/start');assert.equal(started.commands[0].params.threadId,'replacement');
});
test('unloaded, network, authentication and unexpected-ID failures retain the saved binding',async()=>{
  for(const [code,message] of [[-32600,'thread not found: old'],[-32000,'network timeout'],[-32001,'authentication required'],[-32600,'no rollout found for thread id another']]){
    const h=recoveryHarness();const error={code,message};const result=await h.respond('thread/resume',error,error);
    assert.equal(h.calls.resets,0);assert.equal(h.chat.threadId,'old');assert.equal(h.stream.status,'error');
    assert.ok(result.commands.every(c=>!c.method));assert.match(result.commands[0].message,/原会话绑定已保留/);
  }
});
test('read failures and failure to start a new turn never discard saved history or loop',async()=>{
  for(const method of ['thread/read','turn/start','thread/start']){
    const h=recoveryHarness();const error={code:-32600,message:'no rollout found for thread id old'};
    const result=await h.respond(method,error,error);assert.equal(h.calls.resets,0);assert.equal(h.chat.threadId,'old');
    assert.ok(result.commands.every(c=>!c.method));
  }
});
test('a mismatched successful resume response cannot switch thread identity',async()=>{
  const h=recoveryHarness();const result=await h.respond('thread/resume',{thread:{id:'other'}});
  assert.equal(h.stream.status,'error');assert.equal(h.chat.threadId,'old');assert.equal(h.calls.binds,0);
  assert.ok(result.commands.every(c=>!c.method));
});
test('cancel or a manual new conversation cannot be undone by a late resume response',async()=>{
  for(const status of ['cancelled','resuming_thread']){
    const h=recoveryHarness();h.stream.status=status;h.chat.threadId='';
    const result=await h.respond('thread/resume',{thread:{id:'old'}});
    assert.deepEqual(result.commands,[]);assert.equal(h.chat.threadId,'');assert.equal(h.calls.binds,0);
  }
});
