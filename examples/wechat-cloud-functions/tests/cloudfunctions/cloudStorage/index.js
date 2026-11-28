const cloud = require('wx-server-sdk');
const fs = require('fs');
const path = require('path');
cloud.init({env: cloud.DYNAMIC_CURRENT_ENV});
exports.main = async event => {
  if (event.action === 'upload') return cloud.uploadFile({cloudPath:event.cloudPath,fileContent:Buffer.from(event.base64,'base64')});
  if (event.action === 'stream') {
    const filename=path.join(process.env.WECHAT_STORAGE_ROOT,'stream-fixture.bin');
    fs.writeFileSync(filename,Buffer.from([0,255,128,65]));
    return cloud.uploadFile({cloudPath:event.cloudPath,fileContent:fs.createReadStream(filename)});
  }
  if (event.action === 'optional') {
    try { await cloud.downloadFile({fileID:event.fileID}); return {found:true}; }
    catch (error) { return {found:false,code:error.code}; }
  }
  if (event.action === 'read') {
    const result=await cloud.downloadFile({fileID:event.fileID});
    return {base64:result.fileContent.toString('base64'),statusCode:result.statusCode};
  }
  if (event.action === 'nested') return (await cloud.callFunction({name:'cloudStorage',data:{action:'read',fileID:event.fileID}})).result;
  if (event.action === 'urls') return cloud.getTempFileURL({fileList:event.fileList});
  if (event.action === 'delete') return cloud.deleteFile({fileList:event.fileList});
  throw Error('unknown storage fixture action');
};
