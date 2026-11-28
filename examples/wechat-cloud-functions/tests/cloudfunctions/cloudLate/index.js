const cloud = require('wx-server-sdk');
cloud.init();
const db = cloud.database();
exports.main = async () => {
  const id = cloud.getWXContext().OPENID;
  setTimeout(async () => {
    try { await db.collection('contract').doc(id).update({data: {visits: 999}}); } catch (_) {}
  }, 700);
  await new Promise(resolve => setTimeout(resolve, 1000));
};
