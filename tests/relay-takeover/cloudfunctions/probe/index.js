const cloud = require('wx-server-sdk');
cloud.init();
exports.main = async event => {
  const db = cloud.database();
  if (event.action === 'write') {
    await db.collection('takeover_probe').doc(event.id).set({data:{value:event.value,side:process.env.FIXTURE_SIDE}});
    await db.collection('takeover_effects').add({data:{operation:event.id,side:process.env.FIXTURE_SIDE}});
  }
  return {side:process.env.FIXTURE_SIDE, identity:cloud.getWXContext().OPENID,
    data:(await db.collection('takeover_probe').doc(event.id || 'seed').get()).data};
};
