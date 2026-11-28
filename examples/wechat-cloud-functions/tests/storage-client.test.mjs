import test,{assert,exampleRoot} from './support.mjs';
import fs from 'node:fs';
import path from 'node:path';
function setup() {
  const module={exports:{}};new Function('exports','module',fs.readFileSync(path.join(exampleRoot,'client/vhttpd.js'),'utf8'))(module.exports,module);
  let session, fileSize=3, denied=false; const requests=[], downloads=[];
  const wxApi={getStorageSync:()=>session,setStorageSync:(_,value)=>{session=value;},removeStorageSync:()=>{session=undefined;},
    login:({success})=>success({code:'test-code'}),
    getFileSystemManager:()=>({stat:({success})=>success({stats:{size:fileSize}}),readFile:({success})=>success({data:'AP+A'})}),
    downloadFile:options=>{downloads.push(options);options.success({statusCode:200,tempFilePath:'/wx/temp/binary'});},
    request(options){requests.push(options);if(denied)return options.success({statusCode:401,data:{error:{code:'UNAUTHORIZED'}}});
      const data=options.url.endsWith('/auth/login')?{token:'d'.repeat(64),expiresAt:Date.now()+60000}:options.url.endsWith('/storage/upload')?{fileID:'fixture-file',statusCode:200}:options.url.endsWith('/storage/temp-url')?{fileList:[{fileID:'fixture-file',status:0,tempFileURL:'https://files.example.test/signed'}]}:{fileList:[{fileID:'fixture-file',status:0}]};
      options.success({statusCode:200,data});},
  };
  return {client:module.exports.createClient({baseURL:'http://127.0.0.1:19886',wxApi,maxUploadBytes:8}),requests,downloads,
    oversized(){fileSize=9;},deny(){denied=true;}};
}
test('Mini Program storage APIs preserve callback order, binary file paths and token-free signed downloads',async()=>{
  const {client,requests,downloads}=setup(), events=[];
  await client.login();
  const uploaded=await client.uploadFile({cloudPath:'images/test.png',filePath:'/wx/input',success:r=>{assert.equal(r.fileID,'fixture-file');events.push('success');},complete:()=>events.push('complete')}).then(r=>{events.push('resolved');return r;});
  assert.deepEqual(events,['success','complete','resolved']);assert.equal(uploaded.errMsg,'uploadFile:ok');
  assert.equal(requests[1].data.base64,'AP+A');assert.equal(requests[1].data.cloudPath,'images/test.png');
  const file=await client.downloadFile({fileID:uploaded.fileID});assert.equal(file.tempFilePath,'/wx/temp/binary');
  assert.equal(downloads[0].header,undefined);
  assert.equal((await client.getTempFileURL({fileList:[uploaded.fileID]})).fileList[0].status,0);
  assert.equal((await client.deleteFile({fileList:[uploaded.fileID]})).fileList[0].status,0);
});
test('Mini Program storage bounds local reads and never retries uploads/deletions on expired sessions',async()=>{
  const f=setup();await f.client.login();f.oversized();
  await assert.rejects(f.client.uploadFile({cloudPath:'big',filePath:'/wx/big'}),/FILE_TOO_LARGE/);assert.equal(f.requests.length,1);
  f.deny();const events=[];
  await assert.rejects(f.client.deleteFile({fileList:['fixture'],fail:()=>events.push('fail'),complete:()=>events.push('complete')}),/UNAUTHORIZED/);
  assert.deepEqual(events,['fail','complete']);assert.equal(f.requests.length,2);
  await assert.rejects(f.client.deleteFile({fileList:['fixture']}),/LOGIN_REQUIRED/);assert.equal(f.requests.length,2);
});
