import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createFeishuSessionHelpers,completeReplyResponse} from '../../examples/codexbot-app-ts/lib/feishu-session-helpers.mjs';
const source=readFileSync(new URL('../../examples/codexbot-app-ts/lib/commands.mts',import.meta.url),'utf8');
const {feishuText}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
test('one-shot reply constructor captures once and serializer retains revoked context',()=>{
 let calls=0;let retired=false;
 const helpers=createFeishuSessionHelpers({feishuText,helpText:()=> 'help',createReplyContext:(instance)=>{assert.equal(instance,'secondary');calls++;assert.equal(retired,false);return Object.freeze({streamInstance:'secondary',streamId:'reply-'+calls,streamGeneration:'generation-'+calls,streamCreationToken:'a'.repeat(64)});}});
 const response=helpers.handleHelp({instance:'secondary',chatId:'chat',replyTarget:'message',replyTargetType:'message_id'});
 const wire=completeReplyResponse(response);const packet=JSON.stringify(wire);
 assert.equal(calls,1);assert.equal(wire.commands.length,2);assert.equal(wire.commands[0].instance,'secondary');assert.equal(wire.commands[1].instance,'secondary');
 assert.equal(wire.commands[0].target,'message');assert.equal(wire.commands[0].target_type,'message_id');
 assert.equal(wire.commands[0].metadata.creation_token,'a'.repeat(64));
 assert.equal(wire.commands[1].stream_id,wire.commands[0].stream_id);
 assert.equal(wire.commands[1].metadata.stream_generation,wire.commands[0].metadata.stream_generation);
 retired=true;
 assert.equal(JSON.stringify(completeReplyResponse(response)),packet);assert.equal(calls,1);
 assert.deepEqual(completeReplyResponse(wire),wire);
 const stream={streamId:'long',streamGeneration:'long-generation',streamCreationToken:'b'.repeat(64)};
 const long=helpers.feishuReplyText({chatId:'chat'},'ongoing',stream);
 assert.equal(completeReplyResponse({commands:[long]}).commands.length,1);assert.equal(calls,1);
 assert.throws(()=>feishuText('chat','unsigned'),/captured creation context/);
});
test('issuance failure never falls back to unsigned replies',()=>{
 let sends=0;
 const helpers=createFeishuSessionHelpers({helpText:()=> 'help',createReplyContext:()=>{throw new Error('retired host');},feishuText:()=>{sends++;}});
 assert.throws(()=>helpers.handleHelp({chatId:'chat'}),/retired host/);assert.equal(sends,0);
 assert.throws(()=>completeReplyResponse({commands:[{type:'provider.message.send',provider:'feishu',metadata:{one_shot_reply:'1'}}]}),/captured send ownership/);
});
test('unserializable one-shot payload fails before acquiring credentials',()=>{
 let issued=0;
 const helpers=createFeishuSessionHelpers({feishuText,createReplyContext:()=>{issued++;throw new Error('should not issue');}});
 assert.throws(()=>helpers.feishuReplyText({chatId:'chat'},1n),/BigInt/);
 const cyclic={};cyclic.self=cyclic;
 assert.throws(()=>helpers.feishuReplyText({chatId:'chat'},cyclic),/circular/i);
 assert.equal(issued,0);
});
