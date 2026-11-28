const cloud = require('wx-server-sdk');
cloud.init();
exports.main = async (event, context) => {
  const before = cloud.getWXContext();
  const startedAt = Date.now();
  await cloud.database({throwOnNotFound: false}).collection('users').doc(before.OPENID).get();
  await new Promise(resolve => setTimeout(resolve, 100));
  const after = cloud.getWXContext();
  const nested = await cloud.callFunction({name: 'getUser', data: {openid: 'forged'}});
  return {before, after, nested: nested.result, eventOpenid: event.openid,
    laneId: context.laneId, startedAt, finishedAt: Date.now()};
};
