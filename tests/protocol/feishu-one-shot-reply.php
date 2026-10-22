<?php
declare(strict_types=1);
$root=dirname(__DIR__,2);
foreach (['php/package/src/VHttpd/Feishu/CreationLease.php','php/package/src/VHttpd/Feishu/CreationClient.php','examples/codexbot-app/lib/Service/CommandFactory.php','examples/codexbot-app/lib/Service/OneShotReplyService.php','examples/codexbot-app/lib/Upstream/FeishuCommandRouter.php'] as $file) require_once $root.'/'.$file;
use VHttpd\Feishu\CreationClient;
use CodexBot\Service\OneShotReplyService;
use CodexBot\Service\CommandFactory;
function checkReply(bool $ok):void { if (!$ok) throw new RuntimeException('one-shot reply ownership regression'); }
$input=json_decode(stream_get_contents(STDIN),true) ?: [];
if (($input['action'] ?? '') === 'produce') {
 $client=CreationClient::fromEnvironment();
 $service=new OneShotReplyService($client);
 $command=$service->markdown('chat','PHP one-shot');
 echo json_encode(['commands'=>OneShotReplyService::completeCommands([$command])],JSON_THROW_ON_ERROR); exit;
}
$calls=[];$issued=[];$revoked=[];
$client=new CreationClient('http://hub.test','test-admin',function($method,$url,$headers,$body)use(&$calls,&$issued,&$revoked){
 $calls[]=[$method,$url,$headers,$body];checkReply(!str_contains($url,'test-admin'));
 checkReply(in_array('x-vhttpd-admin-token: test-admin',$headers,true));
 if($method==='GET')return ['status'=>200,'body'=>json_encode(['epoch'=>str_repeat('a',64),'issued_at'=>123])];
 $request=json_decode($body,true,flags:JSON_THROW_ON_ERROR);
 if(str_ends_with($url,'/revoke')){$revoked[]=$request;return ['status'=>200,'body'=>'{}'];}
 $issued[]=$request;return ['status'=>200,'body'=>json_encode(['generation'=>'generation-'.count($issued),'token'=>str_repeat(dechex(count($issued)),64)])];
});
$service=new OneShotReplyService($client);
$a=$service->text('chat','hello');$b=$service->markdown('chat','world');
checkReply($a['stream_id']!==$b['stream_id'] && str_starts_with($a['stream_id'],'feishu:reply:'));
checkReply($a['metadata']['creation_token']===str_repeat('1',64));
$wire=OneShotReplyService::completeCommands([$a]);$packet=json_encode($wire,JSON_THROW_ON_ERROR);$count=count($calls);
checkReply(count($wire)===2 && $wire[1]['type']==='session.clear');
checkReply($wire[1]['stream_id']===$wire[0]['stream_id'] && $wire[1]['metadata']['stream_generation']===$wire[0]['metadata']['stream_generation']);
checkReply(!isset($wire[0]['metadata']['one_shot_reply']));
checkReply(OneShotReplyService::completeCommands($wire)===$wire && count($calls)===$count);
$lease=new VHttpd\Feishu\CreationLease($issued[0],$a['metadata']['stream_generation'],$a['metadata']['creation_token']);$client->revoke($lease);
checkReply(count($revoked)===1 && $revoked[0]===$issued[0]);
checkReply(json_encode(OneShotReplyService::completeCommands([$a]),JSON_THROW_ON_ERROR)===$packet);
$count=count($calls);
foreach ([$a,$wire[0],['metadata'=>['creation_token'=>'old']],['stream_id'=>'']] as $payload) {
 $rejected=false;try{$service->command($payload);}catch(InvalidArgumentException){$rejected=true;}checkReply($rejected);
}
checkReply(count($calls)===$count);
foreach (['feishuSendText','feishuSendMarkdown'] as $method) {
 $rejected=false;try{CommandFactory::{$method}('chat','no implicit signature');}catch(LogicException){$rejected=true;}checkReply($rejected);
}
$secondary=$service->forInstance('secondary')->text('chat','secondary');
checkReply($secondary['instance']==='secondary');
checkReply(OneShotReplyService::completeCommands([$secondary])[1]['instance']==='secondary');
// Exercise the real router reply adapters without bootstrapping the unavailable legacy SDK.
$reflection=new ReflectionClass(CodexBot\Upstream\FeishuCommandRouter::class);
$router=$reflection->newInstanceWithoutConstructor();
$reflection->getProperty('replyService')->setValue($router,$service);
$reflection->getProperty('replyInstance')->setValue($router,'secondary');
foreach (['replyText','replyMarkdown'] as $method) {
 $reply=$reflection->getMethod($method)->invoke($router,'chat','router reply');
 checkReply($reply['instance']==='secondary' && str_starts_with($reply['stream_id'],'feishu:reply:'));
 checkReply(count(OneShotReplyService::completeCommands([$reply]))===2);
}
$failure=new OneShotReplyService(new CreationClient('http://hub.test','test-admin',fn()=>['status'=>503,'body'=>'{}']));
$rejected=false;try{$failure->text('chat','fail closed');}catch(RuntimeException){$rejected=true;}checkReply($rejected);
echo "PASS: PHP one-shot replies acquire once, capture credentials, pair exact cleanup, and never re-sign replay\n";
// A lost, malformed or rejected issue response can still follow a server grant.
// Always withdraw the same intent; a failed withdrawal must preserve the issue error.
foreach (['lost','malformed','invalid-token','cleanup-fails'] as $mode) {
 $requests=[];
 $broken=new CreationClient('http://hub.test','test-admin',function($method,$url,$headers,$body)use($mode,&$requests){
  if($method==='GET')return ['status'=>200,'body'=>json_encode(['epoch'=>str_repeat('b',64),'issued_at'=>123])];
  $requests[]=[$url,json_decode($body,true)];
  if(str_ends_with($url,'/revoke')) {
   if($mode==='cleanup-fails')throw new RuntimeException('cleanup unavailable');
   return ['status'=>200,'body'=>'{}'];
  }
  if($mode==='lost' || $mode==='cleanup-fails')throw new RuntimeException('issue response lost');
  return ['status'=>200,'body'=>$mode==='malformed'?'invalid-json':json_encode(['generation'=>'issued','token'=>'bad'])];
 });
 $error=null;try{(new OneShotReplyService($broken))->text('chat','lost reply');}catch(Throwable $failure){$error=$failure;}
 checkReply($error!==null && $error->getMessage()!=='cleanup unavailable');
 checkReply(count($requests)===2 && str_ends_with($requests[1][0],'/revoke') && $requests[0][1]===$requests[1][1]);
}
$before=count($calls);$bad=fopen('php://memory','r');
try{$service->command(['content'=>$bad]);checkReply(false);}catch(JsonException){}finally{fclose($bad);}
checkReply(count($calls)===$before);
echo "PASS: failed issuance withdraws the original intent and serialization fails before issuance\n";
$beforeIssued=count($issued);$beforeRevoked=count($revoked);$error=null;
try{$service->command(['instance'=>7,'target'=>'chat','text'=>'bad instance type']);}catch(InvalidArgumentException $failure){$error=$failure;}
checkReply($error!==null && count($issued)===$beforeIssued+1 && count($revoked)===$beforeRevoked+1);
checkReply($issued[array_key_last($issued)]===$revoked[array_key_last($revoked)]);
echo "PASS: command construction failure withdraws the captured lease\n";
