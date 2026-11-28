const cloud = require('wx-server-sdk');
cloud.init();
exports.main = async () => cloud.database().runTransaction(async tx => {
  await tx.collection('contract').doc(cloud.getWXContext().OPENID).update({data: {visits: 999}});
  await new Promise(resolve => setTimeout(resolve, 1000));
});
