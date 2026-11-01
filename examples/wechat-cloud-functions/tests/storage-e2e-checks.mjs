import {assert} from './support.mjs';
export async function storageChecks(base, alice, bob) {
  async function rpc(route, data, token=alice, status=200) {
    const response=await fetch(base+route,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(data),signal:AbortSignal.timeout(30000)});
    const text=await response.text();assert.equal(response.status,status,route+': '+response.status+' '+text);return JSON.parse(text);
  }
  const sdk=async(data,token=alice,status=200)=>(await rpc('/functions/cloudStorage',data,token,status)).result;
  const bytes=Buffer.from(Array.from({length:256},(_,i)=>i)), data=bytes.toString('base64');
  await rpc('/storage/upload',{cloudPath:'forged',base64:data},null,401);
  const uploaded=await rpc('/storage/upload',{cloudPath:'图片/字节.png',base64:data});
  assert.match(uploaded.fileID,/^cloud:\/\/vhttpd\/[a-f0-9]{32}\/[a-f0-9]{64}$/);
  assert.equal((await sdk({action:'read',fileID:uploaded.fileID})).base64,data);
  assert.equal((await sdk({action:'nested',fileID:uploaded.fileID})).base64,data);
  await sdk({action:'read',fileID:uploaded.fileID},bob,404);
  assert.equal((await sdk({action:'optional',fileID:uploaded.fileID},bob)).found,false);
  assert.equal((await rpc('/storage/temp-url',{fileList:[uploaded.fileID]},bob)).fileList[0].status,1);
  assert.equal((await rpc('/storage/delete',{fileList:[uploaded.fileID]},bob)).fileList[0].status,1);
  const link=(await sdk({action:'urls',fileList:[uploaded.fileID]})).fileList[0].tempFileURL;
  let response=await fetch(link);assert.equal(response.status,200);
  assert.equal(response.headers.get('content-type'),'image/png');assert.equal(response.headers.get('x-content-type-options'),'nosniff');
  assert.equal(Buffer.from(await response.arrayBuffer()).toString('base64'),data);
  const forged=new URL(link);forged.searchParams.set('signature','0'.repeat(64));assert.equal((await fetch(forged.toString())).status,404);
  const samePath=await sdk({action:'stream',cloudPath:'图片/字节.png'});assert.equal(samePath.fileID,uploaded.fileID);
  assert.equal((await fetch(link)).status,404);
  assert.equal((await sdk({action:'read',fileID:uploaded.fileID})).base64,'AP+AQQ==');
  const deleted=await sdk({action:'delete',fileList:[uploaded.fileID,'cloud://vhttpd/invalid/missing']});
  assert.equal(deleted.fileList[0].status,0);assert.equal(deleted.fileList[1].status,1);
  await rpc('/storage/upload',{cloudPath:'../escape',base64:data},alice,400);
  await rpc('/storage/upload',{cloudPath:'bad',base64:'!invalid'},alice,400);
  await rpc('/storage/upload',{cloudPath:'oversized.bin',base64:Buffer.from(new Uint8Array(262145)).toString('base64')},alice,413);
  const large=Buffer.from(new Uint8Array(128*1024).fill(255)).toString('base64');
  const largeFile=await sdk({action:'upload',cloudPath:'large.bin',base64:large});
  const largeURL=(await rpc('/storage/temp-url',{fileList:[largeFile.fileID]})).fileList[0].tempFileURL;
  response=await fetch(largeURL);assert.equal(Buffer.from(await response.arrayBuffer()).toString('base64'),large);
  await rpc('/storage/delete',{fileList:[largeFile.fileID]});assert.equal((await fetch(largeURL)).status,404);
  const empty=await rpc('/storage/upload',{cloudPath:'empty.bin',base64:''});
  assert.equal((await sdk({action:'read',fileID:empty.fileID})).base64,'');
  await rpc('/storage/delete',{fileList:[empty.fileID]});
  const expiring=await rpc('/storage/upload',{cloudPath:'expire.bin',base64:'AA=='});
  const shortURL=(await rpc('/storage/temp-url',{fileList:[{fileID:expiring.fileID,maxAge:1}]})).fileList[0].tempFileURL;
  await new Promise(resolve=>setTimeout(resolve,1100));assert.equal((await fetch(shortURL)).status,404);
  await rpc('/storage/delete',{fileList:[expiring.fileID]});
  const retained=await rpc('/storage/upload',{cloudPath:'restart.bin',base64:'cmVzdGFydA=='},bob);
  const retainedURL=(await rpc('/storage/temp-url',{fileList:[retained.fileID]},bob)).fileList[0].tempFileURL;
  console.log('PASS disk storage: SDK Buffer/ReadStream/nesting, binary HTTP, owner isolation, signed URLs, overwrite/delete revocation, large/empty files and path/base64 validation');
  return {fileID:retained.fileID,url:retainedURL};
}
