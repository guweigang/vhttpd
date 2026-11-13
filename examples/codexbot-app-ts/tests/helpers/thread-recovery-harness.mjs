import {createCodexRpcResponseRouter} from '../../lib/rpc-router.mjs';
import {createThreadSessionCoordinator} from '../../lib/thread-session-coordinator.mjs';
import {buildThreadStartParams,buildTurnStartParams} from '../../lib/codex-start-params.mjs';
export function recoveryHarness(threadId='old') {
  const stream={streamId:'s',sessionKey:'chat',chatId:'chat',prompt:'continue original task',threadId,turnId:'',status:'resuming_thread',codexInstance:'main'};
  const chat={threadId,lastStreamId:'s',model:'model',cwd:'/workspace'};
  const defaults={model:'model',effort:'low',cwd:'/workspace',approvalPolicy:'never',sandbox:'read-only'};
  const calls={resets:0,binds:0};
  const patch=async(_,value)=>{Object.assign(stream,value);return {...stream};};
  const deps={
    buildTag:'test',getStreamState:async()=>({...stream}),ensureChatState:async()=>({...chat}),
    botDefaults:()=>defaults,finalizeStreamState:patch,updateStreamState:patch,
    bindThreadToStream:async(_,id,path)=>{calls.binds++;Object.assign(stream,{threadId:id,threadPath:path});chat.threadId=id;return {stream:{...stream}};},
    fallbackCodexInstance:()=> 'main',buildTurnStartParams,buildThreadStartParams,
    codexTurnStart:(params,streamId,instance)=>({method:'turn/start',params,streamId,instance}),
    codexRpcCall:(method,params,streamId,instance)=>({method,params,streamId,instance}),
    resetChatThread:async()=>{calls.resets++;chat.threadId='';return {...chat};},
    isPlainPromptStream:()=>false,feishuUpdateText:(_,text)=>({message:text}),
    codexRpcErrorText:(method,detail)=>`${method}: ${detail}`,threadExpiredRestartingText:()=> 'history missing; starting new thread',
  };
  const coordinator=createThreadSessionCoordinator(deps);
  const router=createCodexRpcResponseRouter({...deps,continueQueuedTurnStart:coordinator.continueQueuedTurnStart});
  const respond=(method,result,error)=>router({traceId:'s',payloadJson:()=>({method,result,has_error:!!error,raw_response:error?{id:1,error}:undefined}),runtime:{log(){},warn(){}}});
  return {stream,chat,calls,defaults,deps,coordinator,respond};
}
